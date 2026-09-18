# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

repo = File.expand_path("..", __dir__)
ruby = RbConfig.ruby

Dir.mktmpdir("branchproof-rspec-benchmark") do |dir|
  FileUtils.mkdir_p(%w[lib spec test].map { |name| File.join(dir, name) })
  File.write(File.join(dir, "lib", "policy.rb"), "def allowed?(admin, active) = admin && active\n")
  File.write(File.join(dir, "spec", "policy_spec.rb"), <<~RUBY)
    require "policy"
    RSpec.describe "policy" do
      it("allows active admins") { expect(allowed?(true, true)).to be(true) }
      it("rejects inactive admins") { expect(allowed?(true, false)).to be(false) }
    end
  RUBY
  File.write(File.join(dir, "test", "policy_test.rb"), <<~RUBY)
    require "minitest/autorun"
    require "policy"
    class PolicyTest < Minitest::Test
      def test_allows_active_admins = assert allowed?(true, true)
      def test_rejects_inactive_admins = refute allowed?(true, false)
    end
  RUBY
  probe = File.join(dir, "allocation_probe.rb")
  File.write(probe, <<~'RUBY')
    require "json"
    probe_dir = ENV.fetch("BRANCHPROOF_BENCHMARK_PROBE_DIR")
    probe_before = GC.stat(:total_allocated_objects)
    at_exit do
      path = File.join(probe_dir, "#{Process.pid}.json")
      File.write(path, JSON.generate(pid: Process.pid,
                                     allocations: GC.stat(:total_allocated_objects) - probe_before))
    end
  RUBY

  wrappers = {
    native_rspec: <<~RUBY,
      require "rspec/core"
      require "json"
      status = RSpec::Core::Runner.run([File.join(Dir.pwd, "spec/policy_spec.rb")])
      puts "BPBENCH " + JSON.generate(status: status, decisions: nil, vectors: nil, owners: nil)
      exit(status)
    RUBY
    branchproof_rspec: <<~RUBY,
      require "branchproof"
      require "stringio"
      output = StringIO.new
      errors = StringIO.new
      status = Branchproof::CLI.new(stdout: output, stderr: errors).call(%w[analyze lib/**/*.rb --framework rspec --test spec/**/*_spec.rb --format json])
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
      report = JSON.parse(output.string)
      puts "BPBENCH " + JSON.generate(status: status,
                                         decisions: report.dig("metrics", "discovered"),
                                         vectors: report.dig("observations", "vectors").length,
                                         owners: report.dig("observations", "tests").length)
      exit(status)
    RUBY
  }

  wrappers.each { |name, source| File.write(File.join(dir, "#{name}.rb"), source) }
  wrappers.each_key do |name|
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
    probes = Dir[File.join(probe_dir, "*.json")].map { |path| JSON.parse(File.read(path)) }
    raise "#{name} produced no allocation probe" if probes.empty?

    expected_processes = name == :native_rspec ? 1 : 2
    if probes.length != expected_processes
      raise "#{name} expected #{expected_processes} probed processes, got #{probes.length}"
    end

    puts JSON.generate(result.merge(name: name, elapsed_seconds: elapsed.round(4), exit_status: status.exitstatus,
                                    allocations: probes.sum { |probe_data| probe_data.fetch("allocations") },
                                    process_allocations: probes.sort_by { |probe_data| probe_data.fetch("pid") },
                                    stderr_tail: stderr.lines.last(2).join))
  end
end

# rubocop:enable Metrics/BlockLength
