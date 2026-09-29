# frozen_string_literal: true

require "English"
require "rake"
require "rake/tasklib"
require "rbconfig"
require_relative "../branchproof"

module Branchproof
  # Defines a Rake task that runs `branchproof analyze` in a subprocess.
  #
  # The task shells out to the `branchproof` executable, so the isolated
  # worker model is unchanged. Only options the Rakefile sets are passed as
  # CLI flags. Everything else keeps the CLI default, and `.branchproof.json`
  # precedence stays intact.
  #
  # @example Minitest project
  #   require "branchproof/rake_task"
  #
  #   Branchproof::RakeTask.new(:branchproof) do |t|
  #     t.sources = ["lib/**/*.rb"]
  #     t.tests = ["test/**/*_test.rb"]
  #   end
  #
  # @example RSpec project with a coverage gate
  #   Branchproof::RakeTask.new(:branchproof) do |t|
  #     t.sources = ["app/**/*.rb"]
  #     t.framework = "rspec"
  #     t.minimum = ["mcdc=100"]
  #   end
  class RakeTask < ::Rake::TaskLib
    # Option names in the order they appear in the built argv.
    OPTIONS = %i[tests project framework view level missing_only minimum format output].freeze

    # Options that repeat one flag per array item.
    REPEATED_FLAGS = { tests: "--test", minimum: "--minimum" }.freeze

    # CLI defaults. The task only passes a flag when the Rakefile sets it.
    DEFAULTS = { sources: [], tests: [], project: "auto", framework: "auto", view: "decisions", level: 3,
                 missing_only: false, minimum: [], format: "terminal", output: nil, runner_args: [] }.freeze

    # @return [Symbol] the Rake task name
    attr_reader :name

    # @return [String] the task description shown by `rake -T`
    attr_accessor :description

    # Source globs passed as positional arguments.
    # @return [Array<String>]
    attr_reader :sources

    # Test globs, one `--test` flag each.
    # @return [Array<String>]
    attr_reader :tests

    # Project mode: `"auto"`, `"ruby"`, or `"rails"`.
    # @return [String]
    attr_reader :project

    # Test framework: `"auto"`, `"minitest"`, or `"rspec"`.
    # @return [String]
    attr_reader :framework

    # Terminal view: `"decisions"`, `"conditions"`, `"tests"`, or `"decision-tables"`.
    # @return [String]
    attr_reader :view

    # Report level: 1, 2, or 3.
    # @return [Integer]
    attr_reader :level

    # When true, terminal output lists only missing evidence.
    # @return [Boolean]
    attr_reader :missing_only

    # Coverage gates as `"criterion=threshold"` strings, one `--minimum` flag each.
    # @return [Array<String>]
    attr_reader :minimum

    # Output format: `"terminal"` or `"json"`.
    # @return [String]
    attr_reader :format

    # Output path, or nil to write to stdout.
    # @return [String, nil]
    attr_reader :output

    # Extra arguments appended after `--` and passed to the test runner.
    # @return [Array<String>]
    attr_reader :runner_args

    # Defines the task. The block receives the task so a Rakefile can set options.
    #
    # @param name [Symbol, String] the Rake task name
    # @yieldparam task [RakeTask] this task, before it is defined
    def initialize(name = :branchproof)
      super()
      @name = name.to_sym
      @description = "Run branchproof analyze"
      @explicit = {}
      DEFAULTS.each { |key, value| instance_variable_set(:"@#{key}", value.dup) }
      yield self if block_given?
      define
    end

    OPTIONS.each do |option|
      # Each writer records that the Rakefile set the option, so #argv passes its flag.
      define_method(:"#{option}=") do |value|
        @explicit[option] = true
        instance_variable_set(:"@#{option}", value)
      end
    end

    # @param value [Array<String>] source globs
    def sources=(value)
      @sources = Array(value)
    end

    # @param value [Array<String>] runner arguments appended after `--`
    def runner_args=(value)
      @runner_args = Array(value)
    end

    # Builds the CLI arguments without running anything.
    #
    # @return [Array<String>] arguments for `branchproof analyze`
    def argv
      args = ["analyze", *sources]
      OPTIONS.each { |option| args.concat(flags_for(option)) if @explicit[option] }
      args.push("--", *runner_args) unless runner_args.empty?
      args.map(&:to_s)
    end

    # Full command line, starting with the current Ruby and the gem executable.
    #
    # @return [Array<String>]
    def command
      [RbConfig.ruby, executable, *argv]
    end

    # Path to the `branchproof` executable. Works inside this repository and as an installed gem.
    #
    # @return [String]
    def executable
      local = File.expand_path("../../exe/branchproof", __dir__)
      return local if File.file?(local)

      Gem.bin_path("branchproof", "branchproof")
    end

    # Runs the analysis in a subprocess. A non-zero exit status ends the Rake
    # process with the same status so CI fails on coverage gate failures.
    #
    # @return [void]
    def run
      ran = system(*command)
      status = $CHILD_STATUS
      raise Error, "branchproof could not start: #{command.first(2).join(" ")}" if ran.nil? || status.nil?
      return if status.success?

      warn "branchproof exited with status #{status.exitstatus}"
      exit status.exitstatus
    end

    private

    def define
      desc description
      task(name) { run }
    end

    def flags_for(option)
      value = instance_variable_get(:"@#{option}")
      return Array(value).flat_map { |item| [REPEATED_FLAGS.fetch(option), item] } if REPEATED_FLAGS.key?(option)
      return (value ? ["--missing-only"] : []) if option == :missing_only
      return [] if value.nil?

      ["--#{option}", value]
    end
  end
end
