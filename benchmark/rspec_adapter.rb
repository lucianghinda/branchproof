# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

repo = File.expand_path("..", __dir__)
ruby = RbConfig.ruby
examples = Integer(ENV.fetch("EXAMPLES", "2000"))
decisions = Integer(ENV.fetch("DECISIONS", "100"))
repeats = Integer(ENV.fetch("REPEATS", "3"))
raise "EXAMPLES, DECISIONS and REPEATS must be positive" unless [examples, decisions, repeats].all?(&:positive?)

puts JSON.generate(type: "environment", ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM,
                   examples: examples, decisions: decisions, repeats: repeats)

Dir.mktmpdir("branchproof-rspec-benchmark") do |dir|
  FileUtils.mkdir_p(%w[lib spec test].map { |name| File.join(dir, name) })
  File.write(File.join(dir, "lib", "policy.rb"), decisions.times.map do |index|
    "def allowed_#{index}?(admin, active) = admin && active\n"
  end.join)
  File.write(File.join(dir, "spec", "policy_spec.rb"), <<~RUBY)
    require "policy"
    RSpec.describe "policy" do
      #{examples.times.map do |index|
        active = (index / decisions).even?
        "it('case #{index}') { expect(allowed_#{index % decisions}?(true, #{active})).to be(#{active}) }"
      end.join("\n")}
    end
  RUBY
  ordinary_spec = File.read(File.join(dir, "spec", "policy_spec.rb"))
  shared_spec = <<~RUBY
    require "policy"
    RSpec.shared_examples "policy decision" do |index, active|
      it("evaluates policy") { expect(send("allowed_\#{index}?", true, active)).to be(active) }
    end
    RSpec.describe "shared policies" do
      #{examples.times.map do |index|
        "context('case #{index}') { include_examples 'policy decision', #{index % decisions}, #{(index / decisions).even?} }"
      end.join("\n")}
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
  probe = File.join(dir, "allocation_probe.rb")
  File.write(probe, <<~'RUBY')
    require "json"
    require "fiddle"
    unless RUBY_PLATFORM.match?(/darwin|linux/) && Fiddle::SIZEOF_LONG == 8
      raise "The peak RSS probe supports 64-bit macOS and Linux only"
    end
    probe_dir = ENV.fetch("BRANCHPROOF_BENCHMARK_PROBE_DIR")
    # Darwin and Linux rusage start with two timeval structs, then ru_maxrss.
    getrusage = Fiddle::Function.new(Fiddle::Handle::DEFAULT["getrusage"],
                                   [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    probe_before = GC.stat(:total_allocated_objects)
    at_exit do
      path = File.join(probe_dir, "#{Process.pid}.json")
      usage = Fiddle::Pointer.malloc(256)
      raise "getrusage failed" unless getrusage.call(0, usage).zero?
      peak = usage[Fiddle::SIZEOF_LONG * 4, Fiddle::SIZEOF_LONG].unpack1("l!")
      peak *= 1024 unless RUBY_PLATFORM.include?("darwin")
      File.write(path, JSON.generate(pid: Process.pid,
                                     peak_rss_bytes: peak,
                                     allocations: GC.stat(:total_allocated_objects) - probe_before))
    end
  RUBY

  wrappers = {
    native_rspec: <<~RUBY,
      require "rspec/core"
      require "json"
      status = RSpec::Core::Runner.run([File.join(Dir.pwd, "spec/policy_spec.rb")])
      puts "BPBENCH " + JSON.generate(status: status, decisions: nil, vectors: nil, owners: nil,
                                       selected_examples: RSpec.world.example_count)
      exit(status)
    RUBY
    branchproof_rspec: <<~RUBY,
      require "branchproof"
      require "stringio"
      output = StringIO.new
      errors = StringIO.new
      status = Branchproof::CLI.new(stdout: output, stderr: errors).call(%w[analyze lib/**/*.rb --framework rspec --test spec/**/*_spec.rb --format json])
      warn errors.string unless errors.string.empty?
      warn output.string unless status.zero?
      report = JSON.parse(output.string)
      puts "BPBENCH " + JSON.generate(status: status,
                                         decisions: report.dig("metrics", "discovered"),
                                         vectors: report.dig("observations", "vectors").length,
                                         owners: report.dig("observations", "tests").length)
      exit(status)
    RUBY
    branchproof_minitest: <<~RUBY
      require "branchproof"
      require "stringio"
      output = StringIO.new
      errors = StringIO.new
      status = Branchproof::CLI.new(stdout: output, stderr: errors).call(%w[analyze lib/**/*.rb --framework minitest --test test/**/*_test.rb --format json])
      warn errors.string unless errors.string.empty?
      warn output.string unless status.zero?
      report = JSON.parse(output.string)
      puts "BPBENCH " + JSON.generate(status: status,
                                         decisions: report.dig("metrics", "discovered"),
                                         vectors: report.dig("observations", "vectors").length,
                                         owners: report.dig("observations", "tests").length)
      exit(status)
    RUBY
  }

  wrappers.each { |name, source| File.write(File.join(dir, "#{name}.rb"), source) }
  results = []
  %i[ordinary shared].each do |suite|
    File.write(File.join(dir, "spec", "policy_spec.rb"), suite == :ordinary ? ordinary_spec : shared_spec)
    repeats.times do |iteration|
      # Rotate execution order to reduce systematic warm-cache/order bias.
      wrappers.keys.rotate(iteration).each do |name|
        next if suite == :shared && name == :branchproof_minitest

        load_path = name == :native_rspec ? File.join(dir, "lib") : File.join(repo, "lib")
        command = [ruby, "-I#{load_path}", File.join(dir, "#{name}.rb")]
        probe_dir = Dir.mktmpdir("probe", dir)
        inherited_rubyopt = ENV.fetch("RUBYOPT", "").strip
        probe_rubyopt = [inherited_rubyopt, "-r#{probe}"].reject(&:empty?).join(" ")
        environment = { "RUBYOPT" => probe_rubyopt, "BRANCHPROOF_BENCHMARK_PROBE_DIR" => probe_dir }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdout, stderr, status = Open3.capture3(environment, *command, chdir: dir)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        marker = stdout.lines.grep(/^BPBENCH /).last
        raise "#{name} did not emit BPBENCH marker: #{stderr}" unless marker

        raise "#{name} failed with status #{status.exitstatus}: #{stderr}" unless status.success?

        result = JSON.parse(marker.delete_prefix("BPBENCH "))
        if name == :native_rspec && result.fetch("selected_examples") != examples
          raise "Native RSpec did not select the expected examples: #{result}"
        end

        if name != :native_rspec && (result.fetch("owners") != examples || result.fetch("decisions") != decisions)
          raise "#{name} did not observe the expected examples and decisions: #{result}"
        end

        probes = Dir[File.join(probe_dir, "*.json")].map { |path| JSON.parse(File.read(path)) }
        raise "#{name} produced no allocation probe" if probes.empty?

        expected_processes = name == :native_rspec ? 1 : 2
        if probes.length != expected_processes
          raise "#{name} expected #{expected_processes} probed processes, got #{probes.length}"
        end

        row = result.merge(name: name, suite: suite, iteration: iteration + 1, examples: examples,
                           elapsed_seconds: elapsed.round(4), exit_status: status.exitstatus,
                           peak_process_rss_bytes: probes.map { |data| data.fetch("peak_rss_bytes") }.max,
                           allocations: probes.sum { |probe_data| probe_data.fetch("allocations") },
                           process_allocations: probes.sort_by { |probe_data| probe_data.fetch("pid") },
                           stderr_tail: stderr.lines.last(2).join)
        results << row
        puts JSON.generate(row)
      end
    end
  end
  results.group_by { |row| [row.fetch(:suite), row.fetch(:name)] }.each do |(suite, name), rows|
    summary = %i[elapsed_seconds allocations peak_process_rss_bytes].to_h do |metric|
      values = rows.map { |row| row.fetch(metric) }.sort
      middle = values.length / 2
      median = values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
      [metric, { min: values.first, median: median, max: values.last }]
    end
    puts JSON.generate(type: "summary", suite: suite, name: name, repeats: repeats, metrics: summary)
  end
end

# rubocop:enable Metrics/BlockLength
