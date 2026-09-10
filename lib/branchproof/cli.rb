# frozen_string_literal: true

# rubocop:disable Layout/LineLength, Lint/DuplicateBranch

require "json"
require "pathname"
require "tmpdir"
require "open3"
require "rbconfig"
require "stringio"
require "fileutils"
require "securerandom"

module Branchproof
  # Coordinates source inventory, isolated test execution, and report output.
  class CLI
    def initialize(stdout:, stderr:)
      @stdout = stdout
      @stderr = stderr
    end

    def call(argv)
      options = parse(Array(argv))
      return usage_error("analyze is the only supported command") unless options

      inventory = build_inventory(options)
      evidence = empty_evidence(inventory, options)
      baseline = if options[:tests].empty?
                   { status: "INCOMPLETE", executed_tests: 0, failed_tests: 0, skipped_tests: 0, finalized: false }
                 else
                   run_worker(options, inventory, evidence)
                 end
      if value(baseline, :evidence)
        merge_status = evidence.merge(snapshot: value(baseline, :evidence))
        baseline[:merge_status] = merge_status
        if merge_status[:status].to_s == "merged"
          baseline[:evidence] = evidence.snapshot
        else
          baseline[:status] = "ERROR"
          baseline[:finalized] = false
          baseline[:diagnostics] =
            Array(value(baseline,
                        :diagnostics)) + [{ code: "evidence_merge", severity: "error",
                                            message: merge_status[:reason].to_s }]
        end
      end
      if options[:level] >= 2 && value(baseline, :status).to_s == "PASSED"
        analysis = Analyzer.new(inventory: inventory, evidence: evidence.snapshot, limits: options[:limits]).call
        baseline[:analysis] = analysis
        if options[:level] >= 2
          ids = Array(value(inventory, :decisions)).map { |decision| value(decision, :id) }
          baseline[:minima] = ids.filter_map do |decision_id|
            Minimizer.new(analysis: analysis, evidence: evidence.snapshot, limits: options[:limits]).call(objective: :vectors, decision_ids: [decision_id])
          end
          baseline[:minima] += ids.filter_map do |decision_id|
            Minimizer.new(analysis: analysis, evidence: evidence.snapshot, limits: options[:limits]).call(
              objective: :tests, decision_ids: [decision_id]
            )
          end
          baseline[:minima] << Minimizer.new(analysis: analysis, evidence: evidence.snapshot, limits: options[:limits]).call(
            objective: :tests, decision_ids: ids
          )
        end
      end
      diagnostics = Array(value(inventory, :diagnostics)) + Array(value(baseline, :diagnostics)) +
                    Array(value(evidence.snapshot,
                                :diagnostics)) + Array(value(value(baseline, :analysis), :diagnostics))
      analysis = options[:level] == 1 ? nil : value(baseline, :analysis)
      minima = options[:level] == 1 ? [] : Array(value(baseline, :minima))
      report = Report.new(inventory: inventory, evidence: value(baseline, :evidence) || evidence.snapshot,
                          analysis: analysis, minima: minima, baseline: baseline, diagnostics: diagnostics,
                          level: options[:level])
      output_report(report, options)
      report.exit_code
    rescue ArgumentError => e
      usage_error(e.message)
    rescue JSON::ParserError => e
      usage_error("invalid JSON limits: #{e.message}")
    end

    private

    def parse(argv)
      return nil if argv.empty? || argv.first != "analyze"

      args = argv.drop(1)
      delimiter = args.index("--")
      runner_args = delimiter ? args[(delimiter + 1)..] : []
      args = args[0...delimiter] if delimiter
      options = { level: 3, format: :terminal, output: nil, tests: [], source_paths: [], limits: Limits.default,
                  runner_args: runner_args, project: nil }
      until args.empty?
        token = args.shift
        case token
        when "--level"
          level = Integer(args.shift.to_s, 10)
          raise ArgumentError, "level must be 1, 2, or 3" unless (1..3).cover?(level)

          options[:level] = level
        when "--format"
          format = args.shift.to_s
          raise ArgumentError, "format must be terminal or json" unless %w[terminal json].include?(format)

          options[:format] = format.to_sym
        when "--output"
          options[:output] = args.shift
          raise ArgumentError, "--output requires a path" if options[:output].nil? || options[:output].empty?
        when "--test"
          options[:tests] << args.shift
          raise ArgumentError, "--test requires a glob" if options[:tests].last.nil? || options[:tests].last.empty?
        when "--project"
          mode = args.shift
          raise ArgumentError, "--project requires auto, ruby, or rails" if mode.nil? || mode.empty?

          options[:project] = Project.new(root: Dir.pwd, mode: mode).to_h
        when "--limits"
          limits_path = args.shift
          raise ArgumentError, "--limits requires a readable JSON path" unless limits_path && File.file?(limits_path)

          payload = JSON.parse(File.read(limits_path))
          options[:limits] = Limits.normalize(payload.transform_keys(&:to_sym))
        when "--help" then return nil
        else
          raise ArgumentError, "unknown option: #{token}" if token.start_with?("-")

          options[:source_paths] << token
        end
      end
      options[:project] ||= Project.new(root: Dir.pwd, mode: "auto").to_h
      options[:source_paths] = default_sources if options[:source_paths].empty?
      options[:tests] = default_tests if options[:tests].empty?
      options[:tests] = expand_paths(options[:tests], root: options[:project][:root])
      options
    end

    def build_inventory(options)
      test_paths = options[:tests].filter_map do |path|
        File.realpath(path)
      rescue StandardError
        nil
      end
      loaded_paths = $LOADED_FEATURES.filter_map do |path|
        File.realpath(path)
      rescue StandardError
        nil
      end
      selected = expand_paths(options[:source_paths]).reject do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
        canonical = File.realpath(path)
        relative.match?(%r{\A(?:test|spec|tool|vendor)(?:/|\z)}) ||
          test_paths.include?(canonical) || loaded_paths.include?(canonical)
      end
      Source.new(root: Dir.pwd, limits: options[:limits]).inventory(paths: selected)
    end

    def empty_evidence(inventory, options)
      Evidence.new(inventory: inventory, limits: options[:limits], run_id: SecureRandom.uuid)
    end

    def run_worker(options, inventory, evidence)
      begin
        directory = Dir.mktmpdir("branchproof-run-")
        config = File.join(directory, "request.json")
        payload = {
          inventory: inventory, limits: options[:limits], run_id: evidence.run_id,
          test_files: options[:tests], runner_args: options[:runner_args], project: options[:project],
          result_path: File.join(directory, "result.json"), marker_path: File.join(directory, "complete.marker")
        }
        File.binwrite(config, JSON.generate(normalize(payload)))
        script = "require 'branchproof'; exit(Branchproof::Worker.child_process(ARGV.fetch(0)).to_i)"
        child_stdout, stderr, child_status = Open3.capture3(options[:project][:environment], RbConfig.ruby, "-I",
                                                            File.expand_path("..", __dir__), "-e", script, config,
                                                            chdir: options[:project][:root])
        @stderr.write(child_stdout) unless child_stdout.to_s.empty?
        @stderr.write(stderr) unless stderr.to_s.empty?
        unless File.file?(payload[:marker_path]) && File.file?(payload[:result_path])
          return { status: "ERROR", executed_tests: 0, failed_tests: 0, skipped_tests: 0, finalized: false,
                   diagnostics: [{ code: "worker_incomplete", severity: "error", message: stderr.to_s.strip }] }
        end
        result = JSON.parse(File.binread(payload[:result_path]))
        result["exit_status"] = child_status.exitstatus
        if child_status.exitstatus != 0 && result["status"] == "PASSED"
          result["status"] = child_status.exitstatus == 1 ? "FAILED" : "ERROR"
          result["finalized"] = false
        end
        symbolize(result)
      ensure
        FileUtils.remove_entry(directory) if directory && File.directory?(directory)
      end
    rescue StandardError => e
      { status: "ERROR", executed_tests: 0, failed_tests: 0, skipped_tests: 0, finalized: false,
        diagnostics: [{ code: "runner", severity: "error", message: e.message }] }
    end

    def output_report(report, options)
      if options[:output]
        temporary = "#{options[:output]}.tmp-#{Process.pid}"
        File.binwrite(temporary, report_string(report, options[:format]))
        File.rename(temporary, options[:output])
      else
        @stdout.write(report_string(report, options[:format]))
      end
    end

    def report_string(report, format)
      buffer = StringIO.new
      report.write(io: buffer, format: format)
      buffer.string
    end

    def usage_error(message)
      @stderr.write("mcdc: #{message}\n")
      2
    end

    def default_sources
      %w[lib/**/*.rb app/**/*.rb]
    end

    def default_tests
      candidates = Dir.glob("test/**/*_test.rb", base: Dir.pwd) + Dir.glob("test/**/test_*.rb", base: Dir.pwd)
      candidates.map! { |path| File.expand_path(path, Dir.pwd) }
      candidates.reject { |path| default_test_excluded?(path) }.uniq.sort
    end

    def default_test_excluded?(path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
      segments = relative.split(File::SEPARATOR)
      basename = File.basename(path)
      basename == "test_helper.rb" || segments.include?("support") || segments.include?("fixtures")
    end

    def expand_paths(paths, root: Dir.pwd)
      paths.flat_map do |path|
        Dir.glob(path, base: root).map { |item| File.expand_path(item, root) }
      end.uniq.sort
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash[key] || hash[key.to_s]
    end

    def normalize(value)
      case value
      when Hash then value.each_with_object({}) do |(key, item), result|
        result[key.to_s] = normalize(item) unless key.to_s == "original_bytes"
      end
      when Array then value.map { normalize(_1) }
      when Symbol then value.to_s
      when String then value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      when Numeric, TrueClass, FalseClass, NilClass then value
      else value.to_s
      end
    end

    def symbolize(value)
      return value.map { symbolize(_1) } if value.is_a?(Array)
      return value.transform_keys(&:to_sym).transform_values { symbolize(_1) } if value.is_a?(Hash)

      value
    end
  end
end
# rubocop:enable Layout/LineLength, Lint/DuplicateBranch
