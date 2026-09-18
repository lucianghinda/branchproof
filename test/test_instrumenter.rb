# frozen_string_literal: true

require "test_helper"
require "branchproof/instrumenter"
require "branchproof/source"
require "branchproof/limits"
require "tmpdir"
require "open3"
require "tempfile"
require "rbconfig"

class TestInstrumenter < Minitest::Test
  def test_rewrites_a_decision_with_inline_runtime_frames
    source = "value = (left && right)\n"
    unit = {
      original_bytes: source,
      decisions: [{
        id: "decision-1", byte_start: 9, byte_length: 13,
        expression: "left && right",
        tree: { type: :and, left: { type: :atom, index: 0 }, right: { type: :atom, index: 1 } },
        conditions: [
          { index: 0, byte_start: 9, byte_length: 4 },
          { index: 1, byte_start: 17, byte_length: 5 }
        ],
        support_status: :SUPPORTED
      }]
    }

    result = Branchproof::Instrumenter.new.rewrite(unit: unit)

    assert result[:changed], result.inspect
    assert_includes result[:bytes], 'Branchproof::Runtime.enter("decision-1")'
    assert_includes result[:bytes], 'Branchproof::Runtime.condition("decision-1", 0'
    assert_includes result[:bytes], 'Branchproof::Runtime.condition("decision-1", 1'
    assert_equal source.count("\n"), result[:bytes].count("\n")
  end

  def test_skips_unsupported_units_without_changing_bytes
    source = "DATA = __FILE__\n__END__\nignored\n"
    result = Branchproof::Instrumenter.new.rewrite(unit: {
                                                     original_bytes: source, decisions: [], support_status: :UNSUPPORTED,
                                                     support_reasons: ["data_section"]
                                                   })

    refute result[:changed]
    assert_equal source, result[:bytes]
    assert(result[:diagnostics].any? { |diagnostic| diagnostic[:code] == "unsupported_source" })
  end

  def test_rejects_malformed_ranges_without_touching_source
    source = "x = true\n"
    result = Branchproof::Instrumenter.new.rewrite(unit: {
                                                     original_bytes: source,
                                                     decisions: [{ id: "bad", byte_start: 100, byte_length: 3 }]
                                                   })

    refute result[:changed]
    assert_equal source, result[:bytes]
    assert_equal "invalid_range", result[:diagnostics].first[:code]
  end

  def test_original_and_instrumented_source_have_identical_values_and_side_effects
    Dir.mktmpdir("branchproof-instrumentation") do |directory|
      path = File.join(directory, "fixture.rb")
      source = <<~RUBY
        $events = []
        class Box
          def !
            $events << :bang
            false
          end
        end
        def exercise(flag)
          local = :before
          value = if flag && ($events << :rhs; true)
            local = :then
          else
            local = :else
          end
          alt = if !Box.new then :yes else :no end
          [value, local, alt, $events.dup]
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      unit = inventory[:source_units].first
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: unit)
      assert rewritten[:changed], rewritten.inspect

      harness = <<~RUBY
        module Branchproof
          module Runtime
            def self.enter(*) = nil
            def self.condition(_, _, value) = value
            def self.finish(_, value) = value
            def self.leave(*) = nil
            def self.flow_iteration_begin(_, value, *) = value
            def self.flow_iteration_finish(_, value, *) = value
            def self.flow_iteration_leave(*) = nil
            def self.flow_iteration_callback(*) = nil
            def self.set_alternative_count(*) = nil
            def self.value_path(_, value, *) = value
          end
        end
        load ARGV.fetch(0)
        p [exercise(false), exercise(true)]
      RUBY
      original = run_fixture(harness, path, source)
      instrumented = run_fixture(harness, path, rewritten[:bytes])
      assert_equal original, instrumented
      assert_equal "[[:else, :else, :no, [:bang]], [:then, :then, :no, [:bang, :rhs, :bang]]]", original
    end
  end

  def test_inventory_keeps_context_sensitive_predicates_out_of_rewrites
    Dir.mktmpdir("branchproof-unsupported") do |directory|
      path = File.join(directory, "unsupported.rb")
      File.binwrite(path, <<~RUBY)
        def unsupported(value)
          if /needle/
            :regexp
          elsif value .. value
            :flipflop
          elsif <<~TEXT
            heredoc
          TEXT
            :heredoc
          end
        end
      RUBY
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      reasons = inventory[:decisions].flat_map { |decision| decision[:support_reasons] }

      assert_includes reasons, "unsupported_heredoc"
      refute_includes reasons, "unsupported_implicit_regexp"
      refute_includes reasons, "unsupported_flip_flop"
      inventory[:decisions].each do |decision|
        result = Branchproof::Instrumenter.new.rewrite(
          unit: {
            original_bytes: File.binread(path), decisions: [decision],
            support_status: decision[:support_status], support_reasons: decision[:support_reasons]
          }
        )
        if decision[:support_status] == "SUPPORTED"
          assert result[:changed], decision[:context]
        else
          refute result[:changed], decision[:context]
        end
      end
    end
  end

  def test_control_transfers_leave_clean_following_evaluations
    Dir.mktmpdir("branchproof-transfers") do |directory|
      path = File.join(directory, "transfers.rb")
      source = <<~RUBY
        def transfers(flag)
          returned = begin
            return :returned if flag == :return
            :after_return
          end
          loop_result = [1, 2].each do |number|
            next if number == 1 && flag == :next
            break :broken if number == 2 && flag == :break
          end
          thrown = catch(:finish) do
            throw :finish, :thrown if flag == :throw
            :after_throw
          end
          [returned, loop_result, thrown, (true if true)]
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        module Branchproof
          module Runtime
            def self.enter(*) = nil
            def self.condition(_, _, value) = value
            def self.finish(_, value) = value
            def self.leave(*) = nil
            def self.flow_iteration_begin(_, value, *) = value
            def self.flow_iteration_finish(_, value, *) = value
            def self.flow_iteration_leave(*) = nil
            def self.flow_iteration_callback(*) = nil
            def self.set_alternative_count(*) = nil
            def self.value_path(_, value, *) = value
          end
        end
        load ARGV.fetch(0)
        p %i[return next break throw none].map { |flag| transfers(flag == :none ? false : flag) }
      RUBY
      original = run_fixture_output(harness, path, source)
      instrumented = run_fixture_output(harness, path, rewritten[:bytes])
      assert_equal original, instrumented
    end
  end

  def test_logical_right_hand_side_transfers_compile_and_preserve_native_semantics
    path = File.expand_path("fixtures/ruby_constructs/flow_06.rb", __dir__)
    source = File.binread(path)
    inventory = Branchproof::Source.new(root: File.dirname(path), limits: Branchproof::Limits.default)
                                   .inventory(paths: [path])
    rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)

    assert rewritten[:changed], rewritten.inspect
    assert_empty rewritten[:diagnostics]
    assert_instance_of RubyVM::InstructionSequence, rewritten[:iseq]

    harness = <<~RUBY
      module Branchproof
        module Runtime
          def self.enter(*) = nil
          def self.condition(_, _, value) = value
          def self.finish(_, value) = value
          def self.leave(*) = nil
          def self.flow_iteration_begin(_, value, *) = value
          def self.flow_iteration_finish(_, value, *) = value
          def self.flow_iteration_leave(*) = nil
          def self.flow_iteration_callback(*) = nil
          def self.set_alternative_count(*) = nil
          def self.value_path(_, value, *) = value
        end
      end
      def capture(source)
        load source
        [example(false, [1]), example(true, [1, -1, 2])]
      end
      p capture(ARGV.fetch(0))
    RUBY
    original = run_fixture_output(harness, path, source)
    instrumented = run_fixture_output(harness, path, rewritten[:bytes])
    assert_equal original, instrumented
    assert_equal "[nil, [1]]", original.strip

    runtime_harness = <<~RUBY
      require "branchproof"
      class FakeEvidence
        attr_reader :records
        def initialize = @records = []
        def run_id = "flow-06"
        def record(execution:) = (@records << execution; {status: "recorded"})
      end
      evidence = FakeEvidence.new
      Branchproof::Runtime.boot(evidence: evidence)
      load ARGV.fetch(0)
      example(false, [1])
      example(true, [1, -1, 2])
      p evidence.records.map { |record| [record[:status], record[:observations]] }
    RUBY
    assert_equal "[[\"aborted\", [[0, false]]], [\"completed\", [[0, true]]], [\"completed\", [[0, false]]], [\"aborted\", [[0, true]]], [\"completed\", [[0, false], [1, true]]]]",
                 run_fixture(runtime_harness, path, rewritten[:bytes])
  end

  def test_other_native_logical_transfers_compile_without_fabricated_rhs_observations
    sources = {
      "next" => "def example(values)\n  values.each { |value| value && next }\nend\n",
      "redo" => "def example(flag)\n  loop do\n    break unless flag\n    flag && redo\n  end\nend\n",
      "retry" => "def example(flag)\n  begin\n    raise if flag\n  rescue\n    flag && retry\n  end\nend\n",
      "valued" => "def example(flag, values)\n  flag and return :returned\n  values.each { |value| value and break :broken }\nend\n"
    }

    sources.each do |name, source|
      Dir.mktmpdir("branchproof-#{name}") do |directory|
        path = File.join(directory, "fixture.rb")
        File.binwrite(path, source)
        inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
        rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
        assert rewritten[:changed], [name, rewritten].inspect
        assert_empty rewritten[:diagnostics], [name, rewritten].inspect
        assert_instance_of RubyVM::InstructionSequence, rewritten[:iseq]
      end
    end
  end

  def test_nested_predicate_decisions_are_each_instrumented_once
    Dir.mktmpdir("branchproof-nested") do |directory|
      path = File.join(directory, "nested.rb")
      source = <<~RUBY
        def nested(flag)
          if (if flag then true else false end) && flag
            :yes
          else
            :no
          end
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        module Branchproof
          module Runtime
            @events = []
            class << self
              attr_reader :events
              def enter(id) = @events << [:enter, id]
              def condition(id, index, value) = (@events << [:condition, id, index]; value)
              def finish(id, value) = (@events << [:finish, id]; value)
              def leave(id) = @events << [:leave, id]
              def flow_iteration_begin(_, value, *) = value
              def flow_iteration_finish(_, value, *) = value
              def flow_iteration_leave(*) = nil
              def flow_iteration_callback(*) = nil
              def set_alternative_count(*) = nil
              def value_path(_, value, *) = value
            end
          end
        end
        load ARGV.fetch(0)
        nested(true)
        p Branchproof::Runtime.events
      RUBY
      output = run_fixture(harness, path, rewritten[:bytes])
      enters = output.scan(":enter").length
      leaves = output.scan(":leave").length
      assert_equal 2, enters
      assert_equal enters, leaves
      assert_equal 2, output.scan(":finish").length
    end
  end

  def test_three_levels_of_nested_ternaries_are_instrumented_once_each
    Dir.mktmpdir("branchproof-ternary-nested") do |directory|
      path = File.join(directory, "nested.rb")
      source = <<~RUBY
        def nested(a, b, c, d)
          ((a ? b : c) ? d : :middle) ? :left : :right
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      unit = inventory[:source_units].first
      decisions = unit[:decisions].select { |decision| decision[:context] == "ternary" }
      assert_equal 3, decisions.length
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: unit)
      assert rewritten[:changed], rewritten.inspect

      harness = <<~RUBY
        module Branchproof
          module Runtime
            @events = []
            class << self
              attr_reader :events
              def enter(id) = @events << [:enter, id]
              def condition(id, index, value) = (@events << [:condition, id, index]; value)
              def finish(id, value) = (@events << [:finish, id]; value)
              def leave(id) = @events << [:leave, id]
              def flow_iteration_begin(_, value, *) = value
              def flow_iteration_finish(_, value, *) = value
              def flow_iteration_leave(*) = nil
              def flow_iteration_callback(*) = nil
              def set_alternative_count(*) = nil
              def value_path(_, value, *) = value
            end
          end
        end
        load ARGV.fetch(0)
        p nested(true, true, false, true)
        p Branchproof::Runtime.events
      RUBY
      output = run_fixture(harness, path, rewritten[:bytes])
      events = output
      assert_equal 3, events.scan(":enter").length
      assert_equal 3, events.scan(":finish").length
      assert_equal 3, events.scan(":leave").length
      decisions.each do |decision|
        assert_equal 4, events.scan(decision[:id]).length, "unexpected event count for #{decision[:id]}"
      end
    end
  end

  def test_ternary_preserves_truthy_values_identity_and_lazy_evaluation
    Dir.mktmpdir("branchproof-ternary-semantics") do |directory|
      path = File.join(directory, "semantics.rb")
      source = <<~RUBY
        def semantics(flag, events, left, right)
          chosen = flag ? (events << :left; left) : (events << :right; right)
          [chosen.equal?(left), chosen.equal?(right), events]
        end
        def lazy(events)
          [(false && (events << :and_rhs)) ? :bad : :safe,
           (true || (events << :or_rhs)) ? :yes : :bad]
        end
        def assigned(flag)
          result = (value = flag) ? :yes : :no
          [result, value]
        end
        def raises
          true ? (raise "selected") : :unused
        end
      RUBY
      File.binwrite(path, source)
      source_inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default)
      unit = source_inventory.inventory(paths: [path])[:source_units].first
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: unit)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        module Branchproof
          module Runtime
            def self.enter(*) = nil
            def self.condition(_, _, value) = value
            def self.finish(_, value) = value
            def self.leave(*) = nil
            def self.flow_iteration_begin(_, value, *) = value
            def self.flow_iteration_finish(_, value, *) = value
            def self.flow_iteration_leave(*) = nil
            def self.flow_iteration_callback(*) = nil
            def self.set_alternative_count(*) = nil
            def self.value_path(_, value, *) = value
          end
        end
        load ARGV.fetch(0)
        events = []
        left = Object.new
        right = Object.new
        p [semantics(Object.new, events, left, right), semantics(false, events, left, right),
           semantics(nil, events, left, right), lazy(events), assigned(:set), assigned(false)]
        begin
          raises
        rescue RuntimeError => error
          p error.message
        end
      RUBY
      original = run_fixture_output(harness, path, source)
      instrumented = run_fixture_output(harness, path, rewritten[:bytes])
      assert_equal original, instrumented
      assert_includes original, "true, false, [:left, :right, :right]"
      assert_includes original, "[:safe, :yes]"
      assert_includes original, "selected"
    end
  end

  def test_runtime_constant_is_absolute_inside_application_namespace
    Dir.mktmpdir("branchproof-namespace") do |directory|
      path = File.join(directory, "namespace.rb")
      source = <<~RUBY
        module App
          Branchproof = Object.new
          def self.f
            if true
              :ok
            end
          end
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        module Branchproof
          module Runtime
            def self.enter(*) = nil
            def self.condition(_, _, value) = value
            def self.finish(_, value) = value
            def self.leave(*) = nil
            def self.flow_iteration_begin(_, value, *) = value
            def self.flow_iteration_finish(_, value, *) = value
            def self.flow_iteration_leave(*) = nil
            def self.flow_iteration_callback(*) = nil
            def self.set_alternative_count(*) = nil
            def self.value_path(_, value, *) = value
          end
        end
        load ARGV.fetch(0)
        p App.f
      RUBY
      assert_equal ":ok", run_fixture(harness, path, rewritten[:bytes])
    end
  end

  def test_nonlocal_predicate_transfers_are_aborted_and_later_frames_remain_clean
    Dir.mktmpdir("branchproof-aborts") do |directory|
      path = File.join(directory, "aborts.rb")
      source = <<~RUBY
        def abort_return
          if tap { return :returned } && ($events << :rhs)
            :unreachable
          end
        end
        def abort_raise
          if (raise "boom") && ($events << :rhs)
            :unreachable
          end
        end
        def abort_throw
          catch(:done) do
            if throw(:done, :thrown) && ($events << :rhs)
              :unreachable
            end
          end
        end
        def abort_break
          [1].each do
            if tap { break :broken } && ($events << :rhs)
              :unreachable
            end
          end
        end
        def clean
          if true
            :clean
          end
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        require "branchproof"
        class FakeEvidence
          attr_reader :records
          def initialize = @records = []
          def run_id = "abort-run"
          def record(execution:) = (@records << execution; {status: "recorded"})
        end
        evidence = FakeEvidence.new
        $events = []
        Branchproof::Runtime.boot(evidence: evidence)
        load ARGV.fetch(0)
        abort_return
        begin; abort_raise; rescue RuntimeError; end
        abort_throw
        abort_break
        clean
        p evidence.records.map { |record| record[:status] }
      RUBY
      output = run_fixture(harness, path, rewritten[:bytes])
      assert_equal "[\"aborted\", \"aborted\", \"aborted\", \"completed\", \"completed\", \"completed\"]", output
    end
  end

  def test_non_utf8_source_preserves_identity_line_and_binding_semantics
    Dir.mktmpdir("branchproof-encoding") do |directory|
      path = File.join(directory, "identity.rb")
      source = "# encoding: ISO-8859-1\nVALUE = \"caf\\xE9\"\n".b
      source << <<~RUBY.b
        def identity
          x = :bound
          if true
            [VALUE.encoding.name, __FILE__.encoding.name, __LINE__, method(:identity).source_location[1], binding.local_variable_get(:x), VALUE.bytes]
          end
        end
      RUBY
      File.binwrite(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      unit = inventory[:source_units].first
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: unit)
      assert rewritten[:changed], rewritten.inspect
      harness = <<~RUBY
        module Branchproof
          module Runtime
            def self.enter(*) = nil
            def self.condition(_, _, value) = value
            def self.finish(_, value) = value
            def self.leave(*) = nil
            def self.flow_iteration_begin(_, value, *) = value
            def self.flow_iteration_finish(_, value, *) = value
            def self.flow_iteration_leave(*) = nil
            def self.flow_iteration_callback(*) = nil
            def self.set_alternative_count(*) = nil
            def self.value_path(_, value, *) = value
          end
        end
        load ARGV.fetch(0)
        p identity
      RUBY
      output = run_fixture(harness, path, rewritten[:bytes])
      assert_includes output, '"ISO-8859-1"'
      assert_includes output, ":bound"
      assert_includes output, "[99, 97, 102, 233]"
      assert_match(/, 6, 3, :bound,/, output)
    end
  end

  private

  def run_fixture_output(harness, _path, bytes)
    Tempfile.create(["branchproof", ".rb"]) do |file|
      file.write(bytes)
      file.flush
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", harness,
                                             file.path)
      assert status.success?, error
      output
    end
  end

  def run_fixture(harness, _path, bytes)
    Tempfile.create(["branchproof", ".rb"]) do |file|
      file.write(bytes)
      file.flush
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", harness,
                                             file.path)
      assert status.success?, error
      output.lines.last.strip
    end
  end
end
