# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tempfile"
require "timeout"

require "branchproof"

module RubyConstructs
  ROOT = File.expand_path("../fixtures/ruby_constructs", __dir__).freeze
  MANIFESTS = %w[basic patterns flow predicates].freeze
  TIMEOUT = 8

  module_function

  def entries
    @entries ||= MANIFESTS.flat_map { |name| JSON.parse(File.read(File.join(ROOT, "#{name}.json"))) }
                          .sort_by { |entry| entry.fetch("id") }
                          .freeze
  end

  def entry(id)
    entries.find { |candidate| candidate.fetch("id") == id.to_s } || raise(KeyError, "unknown fixture: #{id}")
  end

  def path(id)
    File.join(ROOT, "#{id.to_s.downcase.tr("-", "_")}.rb")
  end

  def inventory(id)
    SourceCache.fetch(id.to_s)[:inventory]
  end

  def capture(id, sample)
    @capture_cache ||= {}
    key = [id.to_s, JSON.generate(sample)]
    return Marshal.load(Marshal.dump(@capture_cache[key])) if @capture_cache.key?(key)

    @capture_cache[key] = capture_uncached(id, sample)
    Marshal.load(Marshal.dump(@capture_cache[key]))
  end

  def capture_uncached(id, sample)
    fixture = SourceCache.fetch(id.to_s)
    rewritten = fixture[:rewritten]
    diagnostics = Array(rewritten[:diagnostics]) + Array(fixture[:inventory][:diagnostics])
    Tempfile.create(["branchproof-construct-", ".rb"]) do |source_file|
      source_file.binmode
      source_file.write(rewritten[:bytes])
      source_file.flush
      inventory_file = Tempfile.new(["branchproof-inventory-", ".json"])
      inventory_file.write(JSON.generate(fixture[:inventory]))
      inventory_file.close
      result_file = Tempfile.new(["branchproof-result-", ".json"])
      evidence_file = Tempfile.new(["branchproof-evidence-", ".json"])
      result_file.close
      evidence_file.close
      owner = "RubyConstructs##{id}/#{sample.fetch("name", "sample")}"
      stdout, stderr, status = run_child(source_file.path, inventory_file.path, sample, result_file.path, evidence_file.path,
                                         owner: owner)
      result = read_json(result_file.path)
      evidence = read_json(evidence_file.path)
      unless sample.key?("exit")
        raise "#{owner}: child failed (#{status.inspect}): #{stderr}" unless status.success?
        raise "#{owner}: child produced no result: #{stderr}" unless result
        raise "#{owner}: child produced no evidence: #{stderr}" unless evidence
      end
      executions = evidence ? symbolize(evidence) : {}
      {
        result: result || { "error" => "ProcessExit" },
        stdout: stdout,
        stderr: stderr,
        exitstatus: status&.exitstatus,
        executions: executions,
        diagnostics: diagnostics + Array(executions[:diagnostics])
      }
    ensure
      result_file&.unlink
      evidence_file&.unlink
      inventory_file&.unlink
    end
  end

  def document(id, reachability: true, cases: nil)
    fixture = SourceCache.fetch(id.to_s)
    selected = cases || entry(id).fetch("cases")
    evidence = Branchproof::Evidence.new(inventory: fixture[:inventory], limits: Branchproof::Limits.default,
                                         run_id: "ruby-constructs-#{id}")
    incomplete = false
    selected.each do |sample|
      owner = "RubyConstructs##{id}/#{sample.fetch("name")}"
      evidence.register_test(test: { id: owner, name: owner, adapter: "ruby_constructs" })
      result = capture(id, sample)
      incomplete ||= sample.key?("exit")
      next if result[:executions].empty?

      merged = evidence.merge(snapshot: result[:executions])
      unless merged[:status] == "merged"
        raise "#{id}/#{sample.fetch("name", "sample")}: evidence merge failed: #{merged.inspect}"
      end
    end
    snapshot = Marshal.load(Marshal.dump(evidence.snapshot))
    snapshot[:completeness] = snapshot.fetch(:completeness).merge(observation: false) if incomplete
    analysis = Branchproof::Analyzer.new(inventory: fixture[:inventory], evidence: snapshot,
                                         limits: Branchproof::Limits.default, reachability: reachability).call
    analysis = analysis.merge(completeness: analysis.fetch(:completeness).merge(observation: false)) if incomplete
    { inventory: fixture[:inventory], evidence: snapshot, analysis: analysis,
      baseline: { status: incomplete ? "INCOMPLETE" : "PASSED", finalized: !incomplete },
      diagnostics: Array(snapshot[:diagnostics]) + Array(analysis[:diagnostics]) }
  end

  def run_child(source_path, inventory_path, sample, result_path, evidence_path, owner:, timeout: TIMEOUT)
    harness = <<~RUBY
      require "json"
      require "branchproof"
      $VERBOSE = nil
      source, inventory_path, sample_path, result_path, evidence_path = ARGV
      sample = JSON.parse(File.read(sample_path))
      inventory = JSON.parse(File.read(inventory_path))
      inventory = inventory.transform_keys(&:to_sym)
      evidence = Branchproof::Evidence.new(inventory: inventory,
                                            limits: Branchproof::Limits.default,
                                            run_id: ENV.fetch("BRANCHPROOF_RUN_ID"))
      Branchproof::Runtime.boot(evidence: evidence)
      Branchproof::Runtime.register_test(test: { id: ENV.fetch("BRANCHPROOF_TEST_ID"),
                                                 name: ENV.fetch("BRANCHPROOF_TEST_ID"), adapter: "ruby_constructs" })
      load source
      Branchproof::Runtime.context(test_id: ENV.fetch("BRANCHPROOF_TEST_ID"), phase: "body")
      begin
        value = example(*sample.fetch("args", []), **sample.fetch("kwargs", {}).transform_keys(&:to_sym))
        File.write(result_path, JSON.generate("result" => value))
      rescue StandardError => error
        File.write(result_path, JSON.generate("error" => error.class.name))
      ensure
        File.write(evidence_path, JSON.generate(Branchproof::Runtime.snapshot))
      end
    RUBY
    manifest_path = Tempfile.new(["branchproof-sample-", ".json"])
    manifest_path.write(JSON.generate(sample))
    manifest_path.close
    env = { "BRANCHPROOF_TEST_ID" => owner,
            "BRANCHPROOF_RUN_ID" => SecureRandom.hex(10) }
    command = [RbConfig.ruby, "-I#{File.expand_path("../../lib", __dir__)}", "-e", harness, source_path,
               inventory_path, manifest_path.path, result_path, evidence_path]
    stdin, stdout_io, stderr_io, wait_thread = Open3.popen3(env, *command, pgroup: true)
    stdin.close
    stdout_thread = Thread.new { stdout_io.read }
    stderr_thread = Thread.new { stderr_io.read }
    begin
      Timeout.timeout(timeout) do
        status = wait_thread.value
        [stdout_thread.value, stderr_thread.value, status]
      end
    rescue Timeout::Error
      begin
        Process.kill("KILL", -wait_thread.pid)
      rescue Errno::ESRCH
        # The child may exit between the deadline and the kill.
      end
      wait_thread.join
      stdout_thread.join
      stderr_thread.join
      raise Timeout::Error, "#{owner}: child exceeded #{timeout} seconds"
    ensure
      stdout_io.close unless stdout_io.closed?
      stderr_io.close unless stderr_io.closed?
      manifest_path.unlink
    end
  end

  def read_json(path)
    body = File.read(path)
    body.empty? ? nil : JSON.parse(body)
  rescue Errno::ENOENT
    nil
  end

  def symbolize(value)
    return value.map { |item| symbolize(item) } if value.is_a?(Array)
    if value.is_a?(Hash)
      return value.each_with_object({}) { |(key, item), result| result[key.to_sym] = symbolize(item) }
    end

    value
  end

  module SourceCache
    module_function

    def fetch(id)
      @cache ||= {}
      @cache[id] ||= begin
        source = Branchproof::Source.new(root: ROOT, limits: Branchproof::Limits.default)
        inv = source.inventory(paths: [RubyConstructs.path(id)])
        rewritten = Branchproof::Instrumenter.new.rewrite(unit: inv[:source_units].first)
        { inventory: inv, rewritten: rewritten }
      end
    end
  end
end
