# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestDefaultCoverage < Minitest::Test
  FIXTURE_ROOT = File.expand_path("fixtures/ruby_constructs", __dir__)

  def test_real_instrumentation_preserves_all_argument_default_behaviors
    cases = {
      "arg_01.rb" => [[[]], [["supplied"]]],
      "arg_02.rb" => [[[], {}], [[], { value: "supplied" }]],
      "arg_03.rb" => [[[], {}], [[5], {}], [[5, 8], {}]],
      "arg_04.rb" => [[["supplied"]], [[[]]]],
      "arg_05.rb" => [[[true], {}], [[false], {}], [[true, "given"], {}]]
    }
    snapshots = []
    cases.each do |filename, invocations|
      source = Branchproof::Source.new(root: FIXTURE_ROOT, limits: Branchproof::Limits.default)
      inventory = source.inventory(paths: [filename])
      original = inventory[:source_units].first.fetch(:original_bytes)
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics], filename
      native = Class.new
      native.class_eval(original)
      instrumented = Class.new
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default,
                                           run_id: "defaults-#{filename}")
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.context(test_id: filename, phase: "body")
      instrumented.class_eval(rewritten[:bytes])
      invocations.each do |args, kwargs|
        args ||= []
        kwargs ||= {}
        assert_equal call_example(native.new, args, kwargs), call_example(instrumented.new, args, kwargs), filename
      end
      if filename == "arg_03.rb"
        default_count = inventory[:decisions].count { |decision| decision[:context] == "default_argument" }
        assert_equal 2, default_count
      end
      snapshots << [inventory, evidence.snapshot]
    ensure
      Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
    end
    defaults = snapshots.flat_map { |item| item[0][:decisions].select { |decision| decision[:context] == "default_argument" } }
    vectors = snapshots.flat_map { |item| item[1][:vectors] }.select do |vector|
      defaults.map { |decision| decision[:id] }.include?(vector[:decision_id])
    end
    assert(vectors.any? { |vector| vector[:values] == [true, false] })
    assert(vectors.any? { |vector| vector[:values] == [false, true] })
  end

  def test_implicit_block_and_empty_parenthesis_shapes_do_not_crash_default_rewrite
    [
      <<~RUBY,
        def with_default(a, b = 1) = a + b
        def uses_it(items) = items.select { it > 0 }
      RUBY
      <<~RUBY,
        def with_default(a, b = 1) = a + b
        def uses_numbered(items) = items.select { _1 > 0 }
      RUBY
      <<~RUBY
        def with_default(a, b = 1) = a + b
        def uses_empty = ->(y = ()) { y }
      RUBY
    ].each do |source|
      rewritten, = rewrite_fixture(source)
      refute_nil rewritten
    end
  end

  def test_second_pass_standard_error_preserves_first_pass_bytes
    assert_second_pass_failure_preserves_first_pass(StandardError, "binding walk failed")
  end

  def test_second_pass_syntax_error_preserves_first_pass_bytes
    assert_second_pass_failure_preserves_first_pass(SyntaxError, "compiled default failed")
  end

  def test_all_gem_library_files_can_be_rewritten_without_raising
    Dir[File.expand_path("../lib/**/*.rb", __dir__)].each do |path|
      root = File.expand_path("..", path)
      inventory = Branchproof::Source.new(root: root, limits: Branchproof::Limits.default).inventory(paths: [path])
      assert_silent { Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first) }
    end
  end

  def test_defaults_remain_valid_after_an_earlier_boolean_rewrite
    source = <<~RUBY
      def earlier(value)
        if value
          :yes
        else
          :no
        end
      end

      def example(value = "default")
        value
      end
    RUBY
    rewritten, = rewrite_fixture(source)
    assert_equal %w[default supplied], evaluate_examples(source, rewritten, [[], ["supplied"]])
  end

  def test_default_expression_assignment_keeps_method_local_scope
    source = <<~RUBY
      def example(value = (local = 1))
        local
      end
    RUBY
    rewritten, = rewrite_fixture(source)
    assert_equal 1, evaluate_examples(source, rewritten, [[]]).first
  end

  def test_raising_later_default_does_not_poison_next_supplied_call
    source = <<~RUBY
      def example(first = 1, second = raise(ArgumentError, "second"))
        [first, second]
      end
    RUBY
    rewritten, inventory = rewrite_fixture(source)
    klass = Class.new
    evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "raise-default")
    Branchproof::Runtime.boot(evidence: evidence)
    klass.class_eval(rewritten)
    Branchproof::Runtime.context(test_id: "raising", phase: "body")
    assert_raises(ArgumentError) { klass.new.example }
    Branchproof::Runtime.context(test_id: "supplied", phase: "body")
    assert_equal [7, 8], klass.new.example(7, 8)
    defaults = inventory[:decisions].select { |decision| decision[:context] == "default_argument" }
    vectors = evidence.snapshot[:vectors]
    first_vectors = vectors.select { |vector| vector[:decision_id] == defaults.fetch(0)[:id] }
    supplied_vectors = first_vectors.select { |vector| vector[:test_ids].include?("supplied") }
    raising_vectors = first_vectors.select { |vector| vector[:test_ids].include?("raising") }
    supplied_values = supplied_vectors.map { |vector| vector[:values] }
    supplied_counts = supplied_vectors.map { |vector| vector[:count] }
    raising_values = raising_vectors.map { |vector| vector[:values] }
    assert_equal [[true, false]], supplied_values
    assert_equal [1], supplied_counts
    assert_equal [[false, true]], raising_values
  ensure
    Branchproof::Runtime.context(test_id: nil, phase: "unattributed")
  end

  def test_empty_endless_and_lambda_bodies_keep_optional_argument_arity
    source = <<~RUBY
      def empty(value = 1)
      end

      def endless(value = 2) = value

      def lambda_example(arguments)
        ->(value = 3) {}.call(*arguments)
      end
    RUBY
    rewritten, = rewrite_fixture(source)
    native = Class.new
    native.class_eval(source)
    klass = Class.new
    klass.class_eval(rewritten)
    %i[empty endless lambda_example].each do |method|
      assert_equal native.new.method(method).arity, klass.new.method(method).arity
    end
    assert_nil klass.new.empty
    assert_nil klass.new.empty(9)
    assert_equal 2, klass.new.endless
    assert_equal 9, klass.new.endless(9)
    assert_nil klass.new.lambda_example([])
    assert_nil klass.new.lambda_example([9])
  end

  private

  def call_example(object, args, kwargs)
    kwargs.empty? ? object.example(*args) : object.example(*args, **kwargs)
  end

  def rewrite_fixture(source)
    Dir.mktmpdir("branchproof-defaults") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      rewritten = Branchproof::Instrumenter.new.rewrite(unit: inventory[:source_units].first)
      assert_empty rewritten[:diagnostics], rewritten.inspect
      return [rewritten[:bytes], inventory]
    end
  end

  def evaluate_examples(original, rewritten, arguments)
    native = Class.new
    native.class_eval(original)
    instrumented = Class.new
    instrumented.class_eval(rewritten)
    arguments.map do |args|
      expected = native.new.example(*args)
      actual = instrumented.new.example(*args)
      assert_equal expected, actual
      actual
    end
  end

  def assert_second_pass_failure_preserves_first_pass(error_class, message)
    source = "def example(value = 1); value; end\n"
    Dir.mktmpdir("branchproof-default-failure") do |directory|
      path = File.join(directory, "fixture.rb")
      File.write(path, source)
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(paths: [path])
      unit = inventory[:source_units].first
      first_pass_method = Branchproof::Instrumenter.instance_method(:rewrite).super_method
      first_pass = first_pass_method.bind(Branchproof::Instrumenter.new).call(unit: unit)
      failing = Class.new(Branchproof::Instrumenter) do
        define_method(:default_body_edits) { |_node, _flags| raise error_class, message }
      end
      result = failing.new.rewrite(unit: unit)
      assert_equal first_pass[:bytes], result[:bytes]
      refute result[:changed]
      assert_nil result[:iseq]
      assert_equal "invalid_default_rewrite", result[:diagnostics].last[:code]
      assert_includes result[:diagnostics].last[:message], message
    end
  end
end
