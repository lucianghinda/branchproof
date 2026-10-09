# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "timeout"
require "branchproof"
require "branchproof/cli"

class WorkerAcceptanceTest < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe", "mcdc")

  def test_worker_streams_both_output_channels_before_completion_and_keeps_json_clean
    project = build_project
    release = File.join(project[:root], "continue")
    write_file(project, "spec/progress_spec.rb", <<~RUBY)
      RSpec.describe "progress" do
        it "waits for the caller to receive progress" do
          puts "stdout progress"
          warn "stderr progress"
          sleep 0.01 until File.exist?(#{release.inspect})
          expect(true).to eq(true)
        end
      end
    RUBY
    args = ["analyze", project[:source], "--framework", "rspec", "--format", "json"]
    output = +""
    progress = +""
    live = false
    Open3.popen3(RbConfig.ruby, EXECUTABLE, *args, chdir: project[:root]) do |input, stdout, stderr, child|
      input.close
      reader = Thread.new { output << stdout.read }
      begin
        Timeout.timeout(5) do
          progress << stderr.readpartial(4096) until progress.include?("stdout progress") && progress.include?("stderr progress")
        end
        live = child.alive?
      rescue Timeout::Error
        live = false
      ensure
        File.write(release, "continue")
      end
      progress << stderr.read
      reader.value
      assert_equal 0, child.value.exitstatus, progress
    end
    assert live, "expected both worker output channels before releasing the running example"
    assert_equal "PASSED", JSON.parse(output).dig("baseline", "status")
  ensure
    cleanup_project(project)
  end

  def test_loader_redefinition_during_helper_boot_is_a_fatal_conflict
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      RubyVM::InstructionSequence.define_singleton_method(:load_iseq) { |_path| nil }
      require "minitest/autorun"
    RUBY
    write_test_file(project)

    result = run_project(project)
    document = result.fetch(:json)

    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_equal "ERROR", document.dig("baseline", "status")
    refute document.dig("baseline", "finalized")
    assert_includes diagnostic_codes(document), "loader_conflict"
    assert_equal false, document.dig("completeness", "observation")
  ensure
    cleanup_project(project)
  end

  def test_source_drift_after_inventory_is_a_fatal_worker_error
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      File.write(ENV.fetch("BRANCHPROOF_SOURCE_PATH"), <<~SOURCE)
        def branchproof_value(value)
          if value
            :changed
          else
            :unchanged
          end
        end
      SOURCE
      require "minitest/autorun"
    RUBY
    write_test_file(project)

    result = run_project(project)
    document = result.fetch(:json)

    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_equal "ERROR", document.dig("baseline", "status")
    refute document.dig("baseline", "finalized")
    assert_includes diagnostic_codes(document), "source_drift"
    assert_equal false, document.dig("completeness", "observation")
  ensure
    cleanup_project(project)
  end

  def test_incomplete_worker_summarizes_exception_and_preserves_stderr_tail
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      80.times { warn "#{__FILE__}:1: warning: Bundler warning #{"x" * 80}" }
      require "pstore/test_helper"
    RUBY
    write_test_file(project)

    result = run_project(project)
    diagnostic = result.fetch(:json).fetch("diagnostics").find { |item| item["code"] == "worker_incomplete" }

    assert_equal 2, result[:status].exitstatus, result[:stderr]
    assert_match(%r{LoadError.*pstore/test_helper}, diagnostic.fetch("message"))
    assert_includes diagnostic.fetch("message"), "test/test_helper.rb"
    refute_includes diagnostic.fetch("message"), "Bundler warning"
    assert_operator diagnostic.dig("details", "stderr").bytesize, :>, 4_000
    assert_operator diagnostic.dig("details", "stderr").bytesize, :<=, 16_384
    assert_includes diagnostic.dig("details", "stderr"), "Bundler warning"
  ensure
    cleanup_project(project)
  end

  def test_incomplete_worker_uses_stdout_when_stderr_contains_only_warnings
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      puts "startup stopped before tests loaded"
      warn "#{__FILE__}:1: warning: Bundler warning"
      exit 1
    RUBY
    write_test_file(project)

    result = run_project(project)
    diagnostic = result.fetch(:json).fetch("diagnostics").find { |item| item["code"] == "worker_incomplete" }

    assert_equal 2, result[:status].exitstatus
    assert_equal "startup stopped before tests loaded", diagnostic.fetch("message")
    assert_equal "startup stopped before tests loaded\n", diagnostic.dig("details", "stdout")
    assert_includes diagnostic.dig("details", "stderr"), "Bundler warning"
  ensure
    cleanup_project(project)
  end

  def test_incomplete_worker_keeps_scrubbed_utf8_tail_within_byte_limit
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      STDERR.binmode
      STDERR.write("z".b + ("é" * 9_000).b + "\\xFF".b + ("x" * 100))
      exit 1
    RUBY
    write_test_file(project)

    result = run_project(project)
    diagnostic = result.fetch(:json).fetch("diagnostics").find { |item| item["code"] == "worker_incomplete" }
    stderr = diagnostic.dig("details", "stderr")

    assert_equal 2, result[:status].exitstatus
    assert_equal result[:json], JSON.parse(result[:stdout])
    assert_operator stderr.bytesize, :<=, 16_384
    assert_predicate stderr, :valid_encoding?
  ensure
    cleanup_project(project)
  end

  def test_worker_failure_summary_uses_first_from_prefixed_application_frame
    Dir.mktmpdir("branchproof project with spaces") do |root|
      status = Open3.capture3(RbConfig.ruby, "-e", "exit 2").last
      stderr = <<~ERROR
        /ruby/lib/bundled_gems.rb:60:in 'Demo::Boot.start': cannot load pstore: expected bundled helper: got missing file (LoadError)
        \tfrom #{root}/test/test_helper.rb:2:in 'require'
      ERROR
      cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)

      summary = cli.send(:worker_failure_summary, "", stderr, root, status)

      assert_equal "LoadError: cannot load pstore: expected bundled helper: got missing file\n  at test/test_helper.rb:2",
                   summary
    end
  end

  def test_worker_failure_summary_does_not_treat_parenthetical_log_as_exception
    Dir.mktmpdir do |root|
      status = Open3.capture3(RbConfig.ruby, "-e", "exit 2").last
      stderr = "#{root}/test/test_helper.rb:8: Cache warming complete (RuntimeError)\n"
      cli = Branchproof::CLI.new(stdout: StringIO.new, stderr: StringIO.new)

      summary = cli.send(:worker_failure_summary, "", stderr, root, status)

      assert_equal stderr.strip, summary
    end
  end

  def test_incomplete_worker_reports_signal_exit_when_no_output_exists
    project = build_project
    write_file(project, "test/test_helper.rb", <<~RUBY)
      Process.kill("TERM", Process.pid)
      sleep
    RUBY
    write_test_file(project)

    result = run_project(project)
    diagnostic = result.fetch(:json).fetch("diagnostics").find { |item| item["code"] == "worker_incomplete" }

    assert_equal 2, result[:status].exitstatus
    assert_equal "worker exited with signal TERM without completing", diagnostic.fetch("message")
    assert_equal "", diagnostic.dig("details", "stderr")
    assert_equal "", diagnostic.dig("details", "stdout")
  ensure
    cleanup_project(project)
  end

  private

  def build_project
    root = Dir.mktmpdir("branchproof-worker-acceptance-")
    project = { root: root, source: File.join(root, "lib", "decision.rb") }
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(root, "test"))
    write_file(project, "lib/decision.rb", <<~RUBY)
      def branchproof_value(value)
        if value
          :yes
        else
          :no
        end
      end
    RUBY
    project
  end

  def write_test_file(project)
    write_file(project, "test/project_test.rb", <<~RUBY)
      require "test_helper"
      require "decision"

      class WorkerTest < Minitest::Test
        def test_worker_reports_boot_failure
          assert true
        end
      end
    RUBY
  end

  def write_file(project, relative_path, content)
    path = File.join(project.fetch(:root), relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def run_project(project)
    args = ["analyze", project.fetch(:source), "--format", "json", "--test",
            File.join(project.fetch(:root), "test/project_test.rb")]
    env = {
      "MT_NO_PLUGINS" => "1",
      "BRANCHPROOF_SOURCE_PATH" => project.fetch(:source)
    }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *args, chdir: project.fetch(:root))
    { stdout: stdout, stderr: stderr, status: status, json: JSON.parse(stdout) }
  end

  def diagnostic_codes(document)
    Array(document["diagnostics"]).map { |diagnostic| diagnostic.fetch("code") }
  end

  def cleanup_project(project)
    FileUtils.remove_entry(project.fetch(:root)) if project && File.directory?(project.fetch(:root))
  end
end
