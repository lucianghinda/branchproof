# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

class TestRSpecLifecycleContract < Minitest::Test
  def test_phase_order_and_source_metadata_match_native_example_lifecycle
    Dir.mktmpdir do |dir|
      spec = File.join(dir, "lifecycle_spec.rb")
      File.write(spec, <<~RUBY)
        RSpec.configure do |config|
          config.before(:suite) { $runtime.mark("suite-before") }
          config.after(:suite) { $runtime.mark("suite-after") }
        end
        RSpec.describe "outer" do
          before(:context) { $runtime.mark("context-before") }
          after(:context) { $runtime.mark("context-after") }
          before { true }
          after { true }
          around do |example|
            $runtime.mark("around-prefix")
            example.run
            $runtime.mark("around-suffix")
          end
          let!(:eager) { $runtime.mark("let-setup"); true }
          let(:lazy) { $runtime.mark("let-body"); true }
          it("works") { expect([eager, lazy]).to include(true) }
        end
      RUBY
      script = File.join(dir, "run.rb")
      lib = File.expand_path("../lib", __dir__)
      File.write(script, <<~RUBY)
        $LOAD_PATH.unshift #{lib.inspect}
        require "json"
        require "rspec"
        require "branchproof/rspec_adapter"
        class Runtime
          attr_reader :events
          def initialize; @events = []; @current = nil; end
          def context(test_id:, phase:); @current = [test_id, phase]; @events << @current; end
          def mark(label); @events << [label, @current]; end
          def register_test(test:); end
          def test_phase_counts; {}; end
        end
        runtime = Runtime.new
        $runtime = runtime
        adapter = Branchproof::RSpecAdapter.new(runtime: runtime)
        adapter.run(test_files: [#{spec.inspect}], runner_args: ["--format", "progress"], test_selection_explicit: true, on_complete: ->(_result) {})
        puts JSON.generate(events: runtime.events, tests: adapter.tests.values)
      RUBY
      output, error, status = Open3.capture3(RbConfig.ruby, script)
      assert_predicate status, :success?, error
      result = JSON.parse(output.lines.last)
      test = result.fetch("tests").first
      events = result.fetch("events")
      phases = events.select { |event| %w[setup body teardown unattributed].include?(event[1]) }.map { |event| event.fetch(1) }.grep_v("unattributed").uniq
      assert_equal %w[setup body teardown], phases
      labels = events.map(&:first)
      assert_operator labels.index("around-prefix"), :<, labels.index("around-suffix")
      assert_operator labels.index("let-setup"), :<, labels.index("let-body")
      assert(events.values_at(labels.index("suite-before"), labels.index("suite-after")).all? { |event| event.fetch(1)&.first.nil? })
      assert(events.values_at(labels.index("context-before"), labels.index("context-after")).all? { |event| event.fetch(1)&.first.nil? })
      test_id = test.fetch("id")
      assert_equal [test_id, "setup"], events.fetch(labels.index("let-setup")).fetch(1)
      assert_equal [test_id, "body"], events.fetch(labels.index("let-body")).fetch(1)
      assert_equal [test_id, "setup"], events.fetch(labels.index("around-prefix")).fetch(1)
      assert_equal [test_id, "teardown"], events.fetch(labels.index("around-suffix")).fetch(1)
      assert_equal File.expand_path(spec), test.dig("source", "path")
      assert_equal "outer works", test.fetch("name")
      assert_nil test.fetch("class_name")
      assert_nil test.fetch("method_name")
    end
  end
end
