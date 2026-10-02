# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestFallbackSource < Minitest::Test
  def test_value_chain_ending_in_string_literal_is_a_multiway_fallback
    decisions = inventory(<<~RUBY)
      def label(name, entry, id)
        name.presence || entry&.title || "Item \#{id}"
      end
    RUBY
    fallback = decisions.find { |decision| decision[:context] == "fallback" }

    assert_equal "multiway", fallback[:kind]
    assert_equal(["name.presence", "entry&.title", "\"Item \#{id}\""],
                 fallback[:alternatives].map { |alternative| alternative[:expression] })
    assert_empty fallback[:conditions]
    assert_equal "SUPPORTED", fallback[:support_status]
  end

  def test_two_operand_fallback_is_implicit
    fallback = inventory("title || \"\"\n").find { |decision| decision[:context] == "fallback" }

    assert_equal "implicit", fallback[:kind]
    assert_equal(["title", "\"\""], fallback[:alternatives].map { |alternative| alternative[:expression] })
  end

  def test_fallback_chain_replaces_the_short_circuit_decision
    contexts = inventory("value = name || other || :none\n").map { |decision| decision[:context] }

    assert_equal ["fallback"], contexts
  end

  def test_safe_navigation_inside_an_operand_keeps_its_own_decision
    contexts = inventory("entry&.title || \"untitled\"\n").map { |decision| decision[:context] }.sort

    assert_equal %w[fallback safe_navigation], contexts
  end

  def test_chain_used_as_an_if_predicate_stays_boolean
    contexts = inventory("if ready || \"yes\"\n  run\nend\n").map { |decision| decision[:context] }

    assert_equal ["if"], contexts
  end

  def test_chains_without_a_non_boolean_truthy_literal_stay_short_circuit
    ["name || other\n", "name || false\n", "name || true\n", "name || nil\n"].each do |source|
      contexts = inventory(source).map { |decision| decision[:context] }

      assert_equal ["short_circuit"], contexts, source
    end
  end

  def test_keyword_or_stays_boolean
    contexts = inventory("name or \"untitled\"\n").map { |decision| decision[:context] }

    assert_equal ["short_circuit"], contexts
  end

  def test_operand_with_its_own_boolean_logic_keeps_the_chain_boolean
    ["(ready && name) || \"untitled\"\n", "!ready || \"untitled\"\n",
     "(ready || name) || \"untitled\"\n"].each do |source|
      contexts = inventory(source).map { |decision| decision[:context] }

      assert_equal ["short_circuit"], contexts, source
    end
  end

  def test_chains_with_a_jump_operand_stay_short_circuit
    [
      "def pick(flag)\n  flag || return || \"z\"\nend\n",
      "items.each { |value| value || next || \"x\" }\n",
      "items.each { |value| value || break || \"x\" }\n",
      "def pick(flag)\n  flag || (return) || \"z\"\nend\n",
      "def pick(flag)\n  flag || (Kernel.puts(:probe); return) || \"z\"\nend\n",
      "def pick(flag)\n  flag || begin\n    Kernel.puts(:probe)\n    return\n  end || \"z\"\nend\n"
    ].each do |source|
      decisions = inventory(source)
      chain = decisions.find { |decision| %w[fallback short_circuit].include?(decision[:context]) }

      assert_equal "short_circuit", chain[:context], source
    end
  end

  private

  def inventory(source)
    Dir.mktmpdir do |root|
      path = File.join(root, "fixture.rb")
      File.write(path, source)
      Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])[:decisions]
    end
  end
end
