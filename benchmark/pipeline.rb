# frozen_string_literal: true

# Benchmark harnesses intentionally keep fixture generation and subprocess
# orchestration together; these narrow exemptions match the existing adapter.
# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Layout/LineLength

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

REPO = File.expand_path("..", __dir__)
RUBY = RbConfig.ruby

def positive_integer(name, default)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  raise ArgumentError, "#{name} must be positive" unless value.positive?

  value
end

def list_option(name, default)
  values = ENV.fetch(name, default).split(",").map(&:strip).reject(&:empty?)
  raise ArgumentError, "#{name} must not be empty" if values.empty?

  values
end

def median(values)
  values = values.sort
  middle = values.length / 2
  values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
end

def write_fixture(dir, examples, decisions)
  File.write(File.join(dir, "lib", "policy.rb"), decisions.times.map do |index|
    "def allowed_#{index}?(admin, active) = admin && active\n"
  end.join)
  ordinary = examples.times.map do |index|
    active = (index / decisions).even?
    "it('case #{index}') { expect(allowed_#{index % decisions}?(true, #{active})).to be(#{active}) }"
  end.join("\n")
  shared = examples.times.map do |index|
    "context('case #{index}') { include_examples 'policy decision', #{index % decisions}, #{(index / decisions).even?} }"
  end.join("\n")
  File.write(File.join(dir, "spec", "policy_spec.rb"), <<~RUBY)
    require "policy"
    RSpec.describe "policy" do
      #{ordinary}
    end
  RUBY
  File.write(File.join(dir, "spec", "shared_policy_spec.rb"), <<~RUBY)
    require "policy"
    RSpec.shared_examples "policy decision" do |index, active|
      it("evaluates policy") { expect(send("allowed_\#{index}?", true, active)).to be(active) }
    end
    RSpec.describe "shared policies" do
      #{shared}
    end
  RUBY
  File.write(File.join(dir, "test", "policy_test.rb"), <<~RUBY)
    require "minitest/autorun"
    require "policy"
    class PolicyTest < Minitest::Test
      #{examples.times.map do |index|
        active = (index / decisions).even?
        "def test_case_#{index} = assert_equal #{active}, allowed_#{index % decisions}?(true, #{active})"
      end.join("\n")}
    end
  RUBY
end

def expected_vector_count(examples, decisions)
  [examples, decisions].min.times.sum do |decision_index|
    observations = ((examples - 1 - decision_index) / decisions) + 1
    observations > 1 ? 2 : 1
  end
end

smoke = ENV["SMOKE"] == "1"
examples = smoke ? 2 : positive_integer("EXAMPLES", 2000)
decisions = smoke ? 1 : positive_integer("DECISIONS", 100)
repeats = smoke ? 1 : positive_integer("REPEATS", 3)
levels = smoke ? [1, 3] : list_option("LEVELS", "1,3").map { |value| Integer(value, 10) }
frameworks = smoke ? %w[rspec minitest] : list_option("FRAMEWORKS", "rspec,minitest")
suites = smoke ? %w[ordinary shared] : list_option("SUITES", "ordinary,shared")
levels.each { |level| raise ArgumentError, "LEVELS must contain 1 or 3" unless [1, 3].include?(level) }
frameworks.each do |framework|
  raise ArgumentError, "unsupported framework: #{framework}" unless %w[rspec minitest].include?(framework)
end
suites.each { |suite| raise ArgumentError, "unsupported suite: #{suite}" unless %w[ordinary shared].include?(suite) }
if frameworks.include?("minitest") && suites == ["shared"]
  raise ArgumentError, "Minitest has no shared suite; include ordinary in SUITES"
end

scenarios = if ENV["MATRIX"] == "1" && !smoke
              ([100, 500, 2000].map { |count| [count, 100] } + [10, 50, 100].map { |count| [2000, count] }).uniq
            else
              [[examples, decisions]]
            end

puts JSON.generate(type: "environment", ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM,
                   levels: levels, frameworks: frameworks, suites: suites, repeats: repeats,
                   scenarios: scenarios)
if frameworks.include?("minitest") && suites.include?("shared")
  puts JSON.generate(type: "notice", message: "Minitest runs the ordinary suite only; shared is RSpec-only")
end

Dir.mktmpdir("branchproof-pipeline") do |dir|
  FileUtils.mkdir_p(%w[lib spec test].map { |name| File.join(dir, name) })
  probe = File.join(dir, "allocation_probe.rb")
  File.write(probe, <<~'RUBY')
    require "json"
    require "fiddle"
    unless RUBY_PLATFORM.match?(/darwin|linux/) && Fiddle::SIZEOF_LONG == 8
      raise "The peak RSS probe supports 64-bit macOS and Linux only"
    end
    probe_dir = ENV.fetch("BRANCHPROOF_BENCHMARK_PROBE_DIR")
    parent_pid = Integer(ENV.fetch("BRANCHPROOF_BENCHMARK_PARENT_PID"), 10)
    getrusage = Fiddle::Function.new(Fiddle::Handle::DEFAULT["getrusage"],
                                      [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    probe_before = GC.stat(:total_allocated_objects)
    at_exit do
      path = File.join(probe_dir, "#{Process.pid}.json")
      usage = Fiddle::Pointer.malloc(256)
      raise "getrusage failed" unless getrusage.call(0, usage).zero?
      peak = usage[Fiddle::SIZEOF_LONG * 4, Fiddle::SIZEOF_LONG].unpack1("l!")
      peak *= 1024 unless RUBY_PLATFORM.include?("darwin")
      File.write(path, JSON.generate(pid: Process.pid, parent_pid: Process.ppid,
                                     process_role: Process.ppid == parent_pid ? "parent" : "worker",
                                     peak_rss_bytes: peak,
                                     allocations: GC.stat(:total_allocated_objects) - probe_before))
    end
  RUBY
  wrapper = File.join(dir, "pipeline_wrapper.rb")
  File.write(wrapper, <<~'RUBY')
    require "json"
    require "branchproof"
    require "stringio"
    module BranchproofPipelineBenchmark
      @phases = Hash.new { |hash, key| hash[key] = { "calls" => 0, "wall_seconds" => 0.0, "allocations" => 0 } }
      @output_report_calls = 0
      @minimization_calls = 0
      class << self
        attr_reader :phases, :output_report_calls, :minimization_calls
        def measure(name)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          allocations = GC.stat(:total_allocated_objects)
          result = yield
          phase = @phases[name]
          phase["calls"] += 1
          phase["wall_seconds"] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          phase["allocations"] += GC.stat(:total_allocated_objects) - allocations
          result
        end
        def output_report_call = @output_report_calls += 1
        def minimization_call = @minimization_calls += 1
      end
      module CLI
        def build_inventory(options) = BranchproofPipelineBenchmark.measure("inventory") { super }
        def run_worker(options, inventory, evidence) = BranchproofPipelineBenchmark.measure("worker") { super }
        def output_report(report, options)
          BranchproofPipelineBenchmark.output_report_call
          super
        end
      end
      module Analyzer
        def call(...) = BranchproofPipelineBenchmark.measure("analysis") { super }
      end
      module Minimizer
        def call(...)
          BranchproofPipelineBenchmark.measure("minimization") do
            BranchproofPipelineBenchmark.minimization_call
            super
          end
        end
      end
      module Report
        def write(...) = BranchproofPipelineBenchmark.measure("rendering") { super }
      end
    end
    Branchproof::CLI.prepend(BranchproofPipelineBenchmark::CLI)
    Branchproof::Analyzer.prepend(BranchproofPipelineBenchmark::Analyzer)
    Branchproof::Minimizer.prepend(BranchproofPipelineBenchmark::Minimizer)
    Branchproof::Report.prepend(BranchproofPipelineBenchmark::Report)
    output = StringIO.new
    errors = StringIO.new
    status = Branchproof::CLI.new(stdout: output, stderr: errors).call(ARGV)
    if output.string.empty?
      warn "BPPIPE_ERROR status=#{status.inspect} stderr=#{errors.string.inspect}"
      exit(status.to_i.zero? ? 1 : status.to_i)
    end
    begin
      report = JSON.parse(output.string)
    rescue JSON::ParserError => error
      warn "BPPIPE_ERROR status=#{status.inspect} parse=#{error.message.inspect} stderr=#{errors.string.inspect}"
      exit(status.to_i.zero? ? 1 : status.to_i)
    end
    baseline = report["baseline"] || {}
    observations = report["observations"] || {}
    metrics = report["metrics"] || {}
    marker = {
      status: status,
      report_status: baseline["status"],
      verified: status.zero? && baseline["status"] == "PASSED",
      evidence_counts: { decisions: metrics["discovered"], vectors: Array(observations["vectors"]).length,
                         tests: Array(observations["tests"]).length },
      phases: BranchproofPipelineBenchmark.phases,
      output_report_calls: BranchproofPipelineBenchmark.output_report_calls,
      minimization_calls: BranchproofPipelineBenchmark.minimization_calls
    }
    puts "BPPIPE " + JSON.generate(marker)
    warn errors.string unless errors.string.empty?
    exit(status)
  RUBY

  results = []
  scenarios.each do |scenario_examples, scenario_decisions|
    write_fixture(dir, scenario_examples, scenario_decisions)
    frameworks.each do |framework|
      (framework == "minitest" ? ["ordinary"] : suites).each do |suite|
        spec_path = suite == "shared" ? "spec/shared_policy_spec.rb" : "spec/policy_spec.rb"
        test_glob = framework == "rspec" ? spec_path : "test/**/*_test.rb"
        repeats.times do |iteration|
          levels.each do |level|
            probe_dir = Dir.mktmpdir("probe", dir)
            inherited_rubyopt = ENV.fetch("RUBYOPT", "").strip
            environment = { "RUBYOPT" => [inherited_rubyopt, "-r#{probe}"].reject(&:empty?).join(" "),
                            "BRANCHPROOF_BENCHMARK_PROBE_DIR" => probe_dir,
                            "BRANCHPROOF_BENCHMARK_PARENT_PID" => Process.pid.to_s }
            command = [RUBY, "-I#{File.join(REPO, "lib")}", wrapper, "analyze", "lib/**/*.rb",
                       "--framework", framework, "--test", test_glob, "--format", "json", "--level", level.to_s,
                       "--no-config"]
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            stdout, stderr, process_status = Open3.capture3(environment, *command, chdir: dir)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            marker = stdout.lines.grep(/^BPPIPE /).last
            raise "missing BPPIPE marker (#{framework}/#{suite}/level#{level}): #{stderr}" unless marker
            raise "benchmark failed: #{stderr}" unless process_status.success?

            data = JSON.parse(marker.delete_prefix("BPPIPE "))
            probes = Dir[File.join(probe_dir, "*.json")].map { |path| JSON.parse(File.read(path)) }
            raise "no allocation probe for #{framework}" if probes.empty?

            roles = probes.map { |probe_data| probe_data.fetch("process_role") }.sort
            raise "expected parent and worker probes, got #{probes}" unless probes.length == 2 && roles == %w[parent worker]

            counts = data.fetch("evidence_counts")
            expected_vectors = expected_vector_count(scenario_examples, scenario_decisions)
            unless data["verified"] && counts["decisions"] == scenario_decisions &&
                   counts["tests"] == scenario_examples && counts["vectors"] == expected_vectors
              raise "unverified report: #{data}"
            end

            expected_minimizations = level == 3 ? ((2 * scenario_decisions) + 1) : 0
            unless data.fetch("minimization_calls") == expected_minimizations
              raise "unexpected minimization count: expected #{expected_minimizations}, got #{data.fetch("minimization_calls")}"
            end

            phase_total = data.fetch("phases").values.sum { |phase| phase.fetch("wall_seconds") }
            row = data.merge("type" => "run", "framework" => framework, "suite" => suite,
                             "level" => level, "iteration" => iteration + 1, "examples" => scenario_examples,
                             "decisions" => scenario_decisions, "elapsed_seconds" => elapsed,
                             "phase_total_seconds" => phase_total,
                             "remainder_seconds" => elapsed - phase_total,
                             "exit_status" => process_status.exitstatus,
                             "peak_process_rss_bytes" => probes.map { |item| item.fetch("peak_rss_bytes") }.max,
                             "allocations" => probes.sum { |item| item.fetch("allocations") },
                             "process_allocations" => probes.sort_by { |item| item.fetch("pid") },
                             "stderr_tail" => stderr.lines.last(2).join)
            results << row
            puts JSON.generate(row)
            FileUtils.remove_entry(probe_dir)
          end
        end
      end
    end
  end
  grouped_results = results.group_by do |row|
    [row.fetch("framework"), row.fetch("suite"), row.fetch("level"), row.fetch("examples"),
     row.fetch("decisions")]
  end
  grouped_results.each do |key, rows|
    values = rows.map { |row| row.fetch("elapsed_seconds") }.sort
    phase_names = rows.flat_map { |row| row.fetch("phases").keys }.uniq.sort
    phase_summary = phase_names.to_h do |phase_name|
      phase_values = rows.map { |row| row.fetch("phases").fetch(phase_name).fetch("wall_seconds") }.sort
      [phase_name, { min: phase_values.first, median: median(phase_values), max: phase_values.last }]
    end
    remainder = rows.map { |row| row.fetch("remainder_seconds") }.sort
    elapsed_summary = { min: values.first, median: median(values), max: values.last }
    remainder_summary = { min: remainder.first, median: median(remainder), max: remainder.last }
    puts JSON.generate(type: "summary", framework: key[0], suite: key[1], level: key[2], examples: key[3], decisions: key[4], repeats: rows.length,
                       elapsed_seconds: elapsed_summary,
                       phases: phase_summary,
                       remainder_seconds: remainder_summary)
  end
end

# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength, Layout/LineLength
