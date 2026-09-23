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
require "time"

module Branchproof
  # Coordinates source inventory, isolated test execution, and report output.
  class CLI
    VIEWS = Report::VIEWS.to_h { |view| [view.to_s.tr("_", "-"), view] }
                         .merge("decision_tables" => :decision_tables).freeze

    def initialize(stdout:, stderr:)
      @stdout = stdout
      @stderr = stderr
    end

    def call(argv)
      argv = Array(argv)
      return help if [["--help"], ["help"], ["analyze", "--help"]].include?(argv)
      return offline(argv) if %w[report compare].include?(argv.first)

      options = parse(argv)
      return usage_error("expected analyze, report, or compare; use branchproof --help") unless options

      inventory = build_inventory(options)
      evidence = empty_evidence(inventory, options)
      baseline = if run_worker?(options)
                   run_worker(options, inventory, evidence)
                 else
                   { status: "INCOMPLETE", executed_tests: 0, failed_tests: 0, skipped_tests: 0, finalized: false }
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
      snapshot = evidence.snapshot
      if value(baseline, :status).to_s == "PASSED"
        analysis = Analyzer.new(inventory: inventory, evidence: snapshot, limits: options[:limits],
                                reachability: options[:reachability]).call
        baseline[:analysis] = analysis
        if options[:level] >= 2
          ids = Array(value(inventory, :decisions)).map { |decision| value(decision, :id) }
          minimizer = Minimizer.new(analysis: analysis, evidence: snapshot, limits: options[:limits])
          baseline[:minima] = ids.filter_map do |decision_id|
            minimizer.call(objective: :vectors, decision_ids: [decision_id])
          end
          baseline[:minima] += ids.filter_map do |decision_id|
            minimizer.call(objective: :tests, decision_ids: [decision_id])
          end
          baseline[:minima] << minimizer.call(objective: :tests, decision_ids: ids)
        end
      end
      diagnostics = Array(value(inventory, :diagnostics)) + Array(value(baseline, :diagnostics)) +
                    Array(value(snapshot,
                                :diagnostics)) + Array(value(value(baseline, :analysis), :diagnostics))
      analysis = value(baseline, :analysis)
      minima = options[:level] == 1 ? [] : Array(value(baseline, :minima))
      report = Report.new(inventory: inventory, evidence: value(baseline, :evidence) || snapshot,
                          analysis: analysis, minima: minima, baseline: baseline, diagnostics: diagnostics,
                          level: options[:level], missing_only: options[:missing_only], view: options[:view],
                          run_metadata: run_metadata(options, baseline), minimum: options[:minimum],
                          focus: options[:focus], top: options[:top])
      output_report(report, options)
      report.exit_code
    rescue ArgumentError => e
      usage_error(e.message)
    rescue JSON::ParserError => e
      usage_error("invalid JSON limits: #{e.message}")
    rescue SystemCallError, IOError => e
      usage_error("report IO failed: #{e.message}")
    end

    private

    def help
      @stdout.write(<<~HELP)
        Usage:
          branchproof analyze [SOURCE_GLOB ...] [--test TEST_GLOB] [--project auto|ruby|rails] [--framework auto|minitest|rspec]
            [--view decisions|conditions|tests|decision-tables] [--level 1|2|3] [--missing-only] [--minimum CRITERION=THRESHOLD]
            [--focus PATH[:LINE]] [--top N]
            [--format terminal|json] [--output PATH] [--limits PATH] [--config PATH|--no-config]
            [--no-reachability] [-- RUNNER_ARGS]
          branchproof report SNAPSHOT [--view decisions|conditions|tests|decision-tables]
            [--level 1|2|3] [--missing-only] [--minimum CRITERION=THRESHOLD] [--focus PATH[:LINE]] [--top N]
            [--format terminal|json] [--output PATH]
          branchproof compare BEFORE AFTER [--format terminal|json] [--output PATH] [--fail-on-regression]
        mcdc accepts the same commands as a compatibility alias.
        JSON always contains full evidence; --view requires terminal output.
        decision_tables is also accepted as an alias for the decision-tables view.
        --no-reachability keeps every generated decision-table rule as a coverage obligation.
      HELP
      0
    end

    def parse_view(view)
      resolved = VIEWS[view.to_s]
      raise ArgumentError, "view must be decisions, conditions, tests, or decision-tables" unless resolved

      resolved
    end

    def validate_view!(options)
      return unless options[:explicit_view] && options[:format] == :json

      raise ArgumentError, "--view requires terminal format; JSON contains full evidence"
    end

    def offline(argv)
      command = argv.first
      return help if argv.drop(1) == ["--help"]

      options, paths = parse_offline(command, argv.drop(1))
      reject_input_output_collision!(paths, options[:output]) if options[:output]
      documents = paths.map { |path| SavedReport.read(path) }
      if command == "compare"
        report = ComparisonReport.new(document: Comparison.new(before: documents[0], after: documents[1]).call)
        output_report(report, options)
        report.exit_code(fail_on_regression: options[:fail_on_regression])
      else
        document = documents.first
        options[:level] ||= document["analysis"] ? 3 : 1
        if options[:level] > 1 && !document["analysis"]
          raise ArgumentError, "saved report has no analysis; use --level 1"
        end
        if options[:missing_only] && (options[:format] != :terminal || options[:level] == 1)
          raise ArgumentError, "--missing-only requires terminal format and level 2 or 3"
        end

        report = Report.from_document(document: document, level: options[:level], view: options[:view],
                                      missing_only: options[:missing_only], minimum: options[:minimum_overrides],
                                      focus: options[:focus], top: options[:top])
        output_report(report, options)
        report.exit_code
      end
    end

    def parse_offline(command, args)
      options = { format: :terminal, view: :decisions, missing_only: false, minimum_overrides: {} }
      paths = []
      until args.empty?
        token = args.shift
        case token
        when "--format"
          format = args.shift
          raise ArgumentError, "format must be terminal or json" unless %w[terminal json].include?(format)

          options[:format] = format.to_sym
        when "--output"
          options[:output] = args.shift
          raise ArgumentError, "--output requires a path" if options[:output].to_s.empty?
        when "--fail-on-regression"
          raise ArgumentError, "--fail-on-regression requires compare" unless command == "compare"

          options[:fail_on_regression] = true
        when "--view", "--level", "--missing-only", "--minimum", "--focus", "--top"
          raise ArgumentError, "#{token} requires report" unless command == "report"

          case token
          when "--view"
            options[:view] = parse_view(args.shift)
            options[:explicit_view] = true
          when "--level"
            options[:level] = Integer(args.shift.to_s, 10)
            raise ArgumentError, "level must be 1, 2, or 3" unless (1..3).cover?(options[:level])
          when "--minimum"
            add_minimum_override!(options, args.shift)
          when "--focus"
            options[:focus] = args.shift
            raise ArgumentError, "--focus requires PATH or PATH:LINE" if options[:focus].nil? || options[:focus].start_with?("-")
          when "--top"
            options[:top] = args.shift
            raise ArgumentError, "--top requires a positive integer" if options[:top].nil?
          else options[:missing_only] = true
          end
        else
          raise ArgumentError, "unknown option: #{token}" if token.start_with?("-")

          paths << token
        end
      end
      expected = command == "compare" ? 2 : 1
      raise ArgumentError, "#{command} requires #{expected} saved report #{expected == 1 ? "path" : "paths"}" unless paths.length == expected

      validate_view!(options)
      validate_selection!(options)
      [options, paths]
    end

    def reject_input_output_collision!(paths, output)
      collision = paths.any? do |input|
        File.expand_path(input) == File.expand_path(output) ||
          (File.exist?(input) && File.exist?(output) && File.identical?(input, output))
      end
      raise ArgumentError, "output must not overwrite an input report" if collision
    end

    def run_metadata(options, baseline)
      root = options[:project][:root]
      locations = Array(value(baseline, :tests)).to_h do |test|
        source = value(test, :source) || {}
        [value(test, :id), { relative_path: relative_path(value(source, :path), root), line: value(source, :line) }]
      end
      project_metadata = value(baseline, :project) || options[:project]
      selected_test_files = value(baseline, :selected_test_files)
      test_files = selected_test_files || options[:tests]
      metadata = {
        captured_at: Time.now.utc.iso8601, requested_level: options[:level], project_kind: options[:project][:kind],
        project_root: root, source_patterns: options[:source_patterns].map { |path| relative_path(path, root) },
        exclude_patterns: Array(options[:exclude]).map { |path| relative_pattern(path, root) },
        test_patterns: options[:test_patterns].map { |path| relative_path(path, root) },
        test_files: Array(test_files).map { |path| relative_path(path, root) }, runner_args: options[:runner_args],
        seed: value(baseline, :seed), limits: options[:limits], test_locations: locations,
        reachability: options[:reachability]
      }
      if options[:configuration]
        metadata[:excluded_files] = Array(options[:excluded_files]).map { |path| relative_path(path, root) }
        metadata[:selected_source_files] = Array(options[:selected_source_files]).map do |path|
          relative_path(path, root)
        end
      end
      %i[selected_test_files selected_example_ids].each do |key|
        metadata[key] = value(baseline, key) if value(baseline, key)
      end
      %i[framework framework_version rspec_rails_version rails_version].each do |key|
        metadata[key] = value(project_metadata, key) if value(project_metadata, key)
      end
      metadata
    end

    def relative_path(path, root)
      return nil if path.to_s.empty?

      Pathname.new(File.expand_path(path, root)).relative_path_from(Pathname.new(root)).to_s
    end

    def relative_pattern(path, root)
      path.to_s.empty? ? path.to_s : relative_path(path, root)
    end

    def parse(argv)
      return nil if argv.empty? || argv.first != "analyze"

      args = argv.drop(1)
      delimiter = args.index("--")
      runner_args = delimiter ? args[(delimiter + 1)..] : []
      args = args[0...delimiter] if delimiter
      options = { level: 3, format: :terminal, output: nil, tests: [], source_paths: [], limits: Limits.default,
                  runner_args: runner_args, project: nil, missing_only: false, view: :decisions,
                  reachability: true, project_mode: "auto", framework: "auto", explicit_tests: false,
                  explicit_project: false, explicit_framework: false, explicit_sources: false,
                  config_path: nil, config_disabled: false, minimum_overrides: {} }
      until args.empty?
        token = args.shift
        case token
        when "--view"
          options[:view] = parse_view(args.shift)
          options[:explicit_view] = true
        when "--missing-only"
          options[:missing_only] = true
        when "--minimum"
          add_minimum_override!(options, args.shift)
        when "--focus"
          options[:focus] = args.shift
          raise ArgumentError, "--focus requires PATH or PATH:LINE" if options[:focus].nil? || options[:focus].start_with?("-")
        when "--top"
          options[:top] = args.shift
          raise ArgumentError, "--top requires a positive integer" if options[:top].nil?
        when "--no-reachability"
          options[:reachability] = false
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

          options[:explicit_tests] = true
        when "--framework"
          options[:framework] = args.shift
          raise ArgumentError, "--framework requires auto, minitest, or rspec" if options[:framework].nil? || options[:framework].empty?

          options[:explicit_framework] = true
        when "--project"
          options[:project_mode] = args.shift
          raise ArgumentError, "--project requires auto, ruby, or rails" if options[:project_mode].nil? || options[:project_mode].empty?

          options[:explicit_project] = true
        when "--config"
          options[:config_path] = args.shift
          raise ArgumentError, "--config requires a readable JSON path" if options[:config_path].nil? || options[:config_path].empty?
        when "--no-config"
          raise ArgumentError, "--config and --no-config are mutually exclusive" if options[:config_path]

          options[:config_disabled] = true
        when "--limits"
          limits_path = args.shift
          raise ArgumentError, "--limits requires a readable JSON path" unless limits_path && File.file?(limits_path)

          payload = JSON.parse(File.read(limits_path))
          options[:limits] = Limits.normalize(payload.transform_keys(&:to_sym))
        when "--help" then return nil
        else
          raise ArgumentError, "unknown option: #{token}" if token.start_with?("-")

          options[:source_paths] << token
          options[:explicit_sources] = true
        end
      end
      root = Dir.pwd
      if options[:config_path] && options[:config_disabled]
        raise ArgumentError, "--config and --no-config are mutually exclusive"
      end

      configuration = Configuration.load(path: options[:config_path] || ".branchproof.json", root: root,
                                         explicit: !options[:config_path].nil?, disabled: options[:config_disabled])
      options[:configuration] = configuration
      if configuration
        options[:project_mode] = configuration[:project] if !options[:explicit_project] && configuration.key?(:project)
        options[:framework] = configuration[:framework] if !options[:explicit_framework] && configuration.key?(:framework)
        if !options[:explicit_sources] && configuration.key?(:sources)
          options[:source_paths] = configuration[:sources].dup
        end
        if !options[:explicit_tests] && configuration.key?(:tests)
          options[:tests] = configuration[:tests].dup
          options[:explicit_tests] = true
        end
        options[:exclude] = Array(configuration[:exclude]).dup
        options[:minimum] = configuration.fetch(:minimum, {}).dup.merge(options[:minimum_overrides])
      else
        options[:exclude] = []
        options[:minimum] = options[:minimum_overrides].dup
      end
      options[:project] = Project.new(root: root, mode: options[:project_mode], framework: options[:framework]).to_h
      validate_view!(options)
      validate_selection!(options)
      if options[:missing_only] && (options[:format] != :terminal || options[:level] == 1)
        raise ArgumentError, "--missing-only requires terminal format and level 2 or 3"
      end

      options[:source_paths] = default_sources if options[:source_paths].empty?
      options[:tests] = default_tests(options[:project]) if options[:tests].empty?
      options[:source_patterns] = options[:source_paths].dup
      options[:test_patterns] = options[:explicit_tests] ? options[:tests].dup : options[:project][:test_patterns]
      options[:tests] = expand_paths(options[:tests], root: options[:project][:root])
      options
    end

    def add_minimum_override!(options, argument)
      text = argument.to_s
      match = text.match(/\A([a-z_]+)=([0-9]+(?:\.[0-9]+)?)\z/)
      raise ArgumentError, "minimum must be CRITERION=THRESHOLD" unless match

      criterion = match[1]
      threshold_text = match[2]
      threshold = threshold_text.include?(".") ? Float(threshold_text) : Integer(threshold_text, 10)
      normalized = CoveragePolicy.normalize(criterion => threshold)
      criterion = normalized.keys.first
      raise ArgumentError, "duplicate coverage criterion: #{criterion}" if options[:minimum_overrides].key?(criterion)

      options[:minimum_overrides][criterion] = normalized.fetch(criterion)
    rescue ArgumentError
      raise
    rescue TypeError
      raise ArgumentError, "minimum threshold must be a finite number from 0 to 100"
    end

    def validate_selection!(options)
      return unless options[:focus] || options[:top]
      raise ArgumentError, "focus and top filters are terminal-only" if options[:format] == :json

      ReportSelection.new(focus: options[:focus], top: options[:top])
    end

    def build_inventory(options)
      root = options[:project][:root]
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
      excluded = expand_paths(Array(options[:exclude]).reject(&:empty?), root: root)
      excluded_paths = excluded.filter_map do |path|
        File.realpath(path)
      rescue StandardError
        nil
      end
      selected = expand_paths(options[:source_paths], root: root).reject do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        canonical = File.realpath(path)
        relative.match?(%r{\A(?:test|spec|tool|vendor)(?:/|\z)}) ||
          test_paths.include?(canonical) || loaded_paths.include?(canonical) || excluded_paths.include?(canonical)
      end
      options[:excluded_files] = excluded
      options[:selected_source_files] = selected
      Source.new(root: root, limits: options[:limits]).inventory(paths: selected)
    end

    def empty_evidence(inventory, options)
      Evidence.new(inventory: inventory, limits: options[:limits], run_id: SecureRandom.uuid)
    end

    def run_worker(options, inventory, evidence)
      begin
        directory = Dir.mktmpdir("branchproof-run-")
        config = File.join(directory, "request.json")
        payload = worker_payload(options, inventory, evidence, directory)
        File.binwrite(config, JSON.generate(normalize(payload)))
        script = "require 'branchproof'; exit(Branchproof::Worker.child_process(ARGV.fetch(0)).to_i)"
        stderr, child_status = stream_worker(options, script, config)
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

    def stream_worker(options, script, config)
      diagnostic_output = +""
      Open3.popen3(options[:project][:environment], RbConfig.ruby, "-I",
                   File.expand_path("..", __dir__), "-e", script, config,
                   chdir: options[:project][:root]) do |input, output, errors, child|
        input.close
        streams = [output, errors]
        until streams.empty?
          IO.select(streams).first.each do |stream|
            chunk = stream.read_nonblock(16_384, exception: false)
            if chunk.nil?
              streams.delete(stream)
            elsif chunk != :wait_readable
              @stderr.write(chunk)
              @stderr.flush if @stderr.respond_to?(:flush)
              diagnostic_output << chunk
              diagnostic_output = diagnostic_output.byteslice(-16_384, 16_384) if diagnostic_output.bytesize > 16_384
            end
          end
        end
        [diagnostic_output, child.value]
      end
    end

    def output_report(report, options)
      created = false
      if options[:output]
        temporary = "#{options[:output]}.tmp-#{SecureRandom.hex(12)}"
        File.open(temporary, "wx") do |file|
          created = true
          file.write(report_string(report, options[:format]))
        end
        File.rename(temporary, options[:output])
      else
        @stdout.write(report_string(report, options[:format]))
      end
    ensure
      File.unlink(temporary) if created && temporary && File.file?(temporary)
    end

    def run_worker?(options)
      !options[:tests].empty? || options[:project][:framework].to_s == "rspec"
    end

    def worker_payload(options, inventory, evidence, directory)
      {
        inventory: inventory, limits: options[:limits], run_id: evidence.run_id,
        test_files: options[:tests], runner_args: options[:runner_args], project: options[:project],
        test_selection_explicit: options[:explicit_tests],
        result_path: File.join(directory, "result.json"), marker_path: File.join(directory, "complete.marker")
      }
    end

    def report_string(report, format)
      buffer = StringIO.new
      report.write(io: buffer, format: format)
      buffer.string
    end

    def usage_error(message)
      @stderr.write("branchproof: #{message}\n")
      2
    end

    def default_sources
      %w[lib/**/*.rb app/**/*.rb]
    end

    def default_tests(project = nil)
      project ||= Project.new(root: Dir.pwd, mode: "auto", framework: "auto").to_h
      candidates = Array(project[:test_patterns]).flat_map { |pattern| Dir.glob(pattern, base: project[:root]) }
      candidates.map! { |path| File.expand_path(path, Dir.pwd) }
      candidates.reject { |path| default_test_excluded?(path) }.uniq.sort
    end

    def default_test_excluded?(path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(Dir.pwd)).to_s
      segments = relative.split(File::SEPARATOR)
      basename = File.basename(path)
      %w[test_helper.rb spec_helper.rb rails_helper.rb].include?(basename) ||
        segments.include?("support") || segments.include?("fixtures")
    end

    def expand_paths(paths, root: Dir.pwd)
      paths.flat_map do |path|
        Dir.glob(path, base: root).map { |item| File.expand_path(item, root) }
      end.uniq.sort
    end

    def value(hash, key)
      return nil unless hash.respond_to?(:key?)

      hash.key?(key) ? hash[key] : hash[key.to_s]
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
