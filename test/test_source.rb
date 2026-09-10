# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestSource < Minitest::Test
  def test_inventory_finds_ordered_if_elsif_unless_and_modifiers
    Dir.mktmpdir do |root|
      path = File.join(root, "sample.rb")
      File.binwrite(path, <<~RUBY)
        if first && second
        elsif third
        end
        work unless skipped
        value if modifier
      RUBY

      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      assert_equal 4, inventory[:decisions].length
      assert_equal(%w[if elsif unless if], inventory[:decisions].map { |d| d[:context] })
      assert_equal([2, 1, 1, 1], inventory[:decisions].map { |d| d[:conditions].length })
      assert_equal 4, inventory[:decisions].map { |d| d[:id] }.uniq.length
      assert(inventory[:decisions].all? { |d| d[:byte_length].positive? })
    end
  end

  def test_inventory_supports_ternary_predicates_and_keeps_predicate_ranges
    Dir.mktmpdir do |root|
      path = File.join(root, "ternary.rb")
      source = "value = first && second ? :yes : :no\n"
      File.binwrite(path, source)

      source_inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default)
      decision = source_inventory.inventory(paths: [path])[:decisions].first

      assert_equal "ternary", decision[:context]
      assert_equal "first && second", decision[:expression]
      assert_equal source.index("first"), decision[:byte_start]
      assert_equal "first && second".bytesize, decision[:byte_length]
      assert_equal 2, decision[:conditions].length
      assert_equal :and, decision[:tree][:type]
      assert_equal "SUPPORTED", decision[:support_status]
      refute_includes decision[:support_reasons], "unsupported_ternary"
    end
  end

  def test_ternary_inventory_retains_nested_decisions_and_unsafe_guards
    Dir.mktmpdir do |root|
      path = File.join(root, "nested.rb")
      File.write(path, <<~RUBY)
        value = ((a ? b : c) ? d : e) ? left : right
        if value ? first : second
        end
        value = (first; second) ? yes : no
        value = (first and second) ? yes : no
      RUBY

      source_inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default)
      decisions = source_inventory.inventory(paths: [path])[:decisions]
      ternaries = decisions.select { |decision| decision[:context] == "ternary" }

      assert_equal 6, ternaries.length
      assert_equal ternaries.length, ternaries.map { |decision| decision[:id] }.uniq.length
      assert(ternaries.all? { |decision| decision[:byte_length].positive? })
      assert(ternaries.any? { |decision| decision[:support_status] == "SUPPORTED" })
      assert(decisions.any? { |decision| decision[:support_reasons].include?("unsupported_control_expression") })
      assert(decisions.any? { |decision| decision[:support_reasons].include?("unsupported_keyword_boolean") })
    end
  end

  def test_ternary_condition_limit_remains_enforced
    Dir.mktmpdir do |root|
      path = File.join(root, "limited.rb")
      predicate = Array.new(65, "flag").join(" && ")
      File.write(path, "value = #{predicate} ? yes : no\n")
      limits = Branchproof::Limits.normalize(conditions_per_decision: 64)
      decision = Branchproof::Source.new(root: root, limits: limits).inventory(paths: [path])[:decisions].first

      assert_equal "ternary", decision[:context]
      assert_equal 65, decision[:discovered_condition_count]
      assert_includes decision[:support_reasons], "condition_limit_exceeded"
      assert_equal "UNSUPPORTED", decision[:support_status]
    end
  end

  def test_inventory_is_deterministic_and_digest_changes_with_bytes
    Dir.mktmpdir do |root|
      path = File.join(root, "sample.rb")
      File.binwrite(path, "if ready\nend\n")
      source = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default)
      first = source.inventory(paths: [path])
      second = source.inventory(paths: [path])
      assert_equal first, second
      File.binwrite(path, "if changed\nend\n")
      refute_equal first[:source_units].first[:digest], source.inventory(paths: [path])[:source_units].first[:digest]
    end
  end

  def test_source_encoding_falls_back_when_prism_source_has_no_encoding_api
    source = Branchproof::Source.new(root: Dir.pwd, limits: Branchproof::Limits.default)
    parsed = Struct.new(:source).new(Object.new)

    assert_equal "ISO-8859-1", source.send(:source_encoding, "# encoding: ISO-8859-1\nif true\nend\n".b, parsed)
    assert_equal "UTF-8", source.send(:source_encoding, "if true\nend\n".b, parsed)
  end

  def test_unsafe_syntax_is_diagnosed
    Dir.mktmpdir do |root|
      path = File.join(root, "unsafe.rb")
      File.binwrite(path, "if /pattern/\nend\n")
      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      assert(inventory[:diagnostics].any? { |d| d[:code] == "unsupported_implicit_regexp" })
    end
  end

  def test_inventory_preserves_byte_ranges_and_nested_boolean_tree
    Dir.mktmpdir do |root|
      path = File.join(root, "utf8.rb")
      source = "é; if (first && (second || third))\nend\n"
      File.binwrite(path, source.encode(Encoding::UTF_8))
      decision = Branchproof::Source.new(root: root,
                                         limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions].first
      assert_equal source.byteslice(decision[:byte_start], decision[:byte_length]), decision[:expression]
      assert_equal :and, decision[:tree][:type]
      assert_equal :or, decision[:tree][:right][:type]
      assert_equal(%w[unknown unknown unknown], decision[:conditions].map { |c| c[:coupling] })
    end
  end

  def test_inventory_marks_ambiguous_and_unsafe_forms
    Dir.mktmpdir do |root|
      path = File.join(root, "unsafe.rb")
      File.binwrite(path, <<~RUBY)
        if (false; true)
        end
        if first and second
        end
        if /pattern/
        end
        __END__
        if ignored
        end
      RUBY
      decisions = Branchproof::Source.new(root: root,
                                          limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions]
      assert(decisions.all? { |d| d[:support_status] == "UNSUPPORTED" })
      assert(decisions.any? { |d| d[:support_reasons].include?("unsupported_keyword_boolean") })
      assert(decisions.any? { |d| d[:support_reasons].include?("unsupported_implicit_regexp") })
      assert(decisions.any? { |d| d[:support_reasons].include?("unsupported_data_section") })
    end
  end

  def test_literals_and_condition_limit_are_visible
    Dir.mktmpdir do |root|
      path = File.join(root, "limits.rb")
      File.write(path, "if true && false && nil\nend\n")
      limits = Branchproof::Limits.normalize(conditions_per_decision: 2)
      decision = Branchproof::Source.new(root: root, limits: limits).inventory(paths: [path])[:decisions].first
      assert_equal 3, decision[:discovered_condition_count]
      assert_equal([true, false], decision[:conditions].map { |c| c[:literal_truth] })
      assert_includes decision[:support_reasons], "condition_limit_exceeded"
    end
  end

  def test_paths_require_strings_and_ambiguous_parentheses_are_unsupported
    source = Branchproof::Source.new(root: Dir.pwd, limits: Branchproof::Limits.default)
    assert_raises(ArgumentError) { source.inventory(paths: [nil]) }
    Dir.mktmpdir do |root|
      path = File.join(root, "ambiguous.rb")
      File.write(path, "if (first; second)\nend\n")
      decision = source.class.new(root: root,
                                  limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions].first
      assert_equal "UNSUPPORTED", decision[:support_status]
      assert_includes decision[:support_reasons], "unsupported_control_expression"
    end
  end

  def test_condition_limit_retains_discovered_count_without_unbounded_tree
    Dir.mktmpdir do |root|
      path = File.join(root, "many.rb")
      predicate = Array.new(65, "flag").join(" || ")
      File.write(path, "if #{predicate}\nend\n")
      decision = Branchproof::Source.new(root: root,
                                         limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions].first
      assert_equal 65, decision[:discovered_condition_count]
      assert_nil decision[:tree]
      assert_equal 64, decision[:conditions].length
      assert_equal "UNSUPPORTED", decision[:support_status]
    end
  end

  def test_symlink_aliases_share_canonical_source_identity
    Dir.mktmpdir do |parent|
      real_root = File.join(parent, "real")
      alias_root = File.join(parent, "alias")
      Dir.mkdir(real_root)
      File.write(File.join(real_root, "x.rb"), "if ready\nend\n")
      begin
        File.symlink(real_root, alias_root)
      rescue NotImplementedError
        skip "symlinks unavailable"
      end
      real = Branchproof::Source.new(root: real_root, limits: Branchproof::Limits.default).inventory(paths: ["x.rb"])
      aliased = Branchproof::Source.new(root: alias_root, limits: Branchproof::Limits.default).inventory(paths: ["x.rb"])
      assert_equal "x.rb", aliased[:source_units].first[:relative_path]
      assert_equal real[:source_units].first[:source_id], aliased[:source_units].first[:source_id]
      both = Branchproof::Source.new(root: real_root,
                                     limits: Branchproof::Limits.default).inventory(paths: [
                                                                                      "x.rb", File.join(alias_root, "x.rb")
                                                                                    ])
      assert_equal 1, both[:source_units].length
    end
  end

  def test_invalid_parse_has_diagnostic_and_no_supported_decisions
    Dir.mktmpdir do |root|
      path = File.join(root, "invalid.rb")
      File.write(path, "if (\n")
      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      assert(inventory[:decisions].all? { |decision| decision[:support_status] == "UNSUPPORTED" })
      assert(inventory[:diagnostics].any? { |d| d[:code] == "parse_error" })
    end
  end
end
