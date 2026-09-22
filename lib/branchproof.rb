# frozen_string_literal: true

require_relative "branchproof/version"
require_relative "branchproof/records"
require_relative "branchproof/limits"
require_relative "branchproof/source"
require_relative "branchproof/project"

# Public namespace for source inventory and one-run MC/DC reporting.
module Branchproof
  class Error < StandardError; end
  autoload :Configuration, "branchproof/configuration"
  autoload :CLI, "branchproof/cli"
  autoload :Instrumenter, "branchproof/instrumenter"
  autoload :Loader, "branchproof/loader"
  autoload :Runtime, "branchproof/runtime"
  autoload :MinitestAdapter, "branchproof/minitest_adapter"
  autoload :RSpecAdapter, "branchproof/rspec_adapter"
  autoload :Evidence, "branchproof/evidence"
  autoload :Analyzer, "branchproof/analyzer"
  autoload :Constraints, "branchproof/constraints"
  autoload :DecisionTable, "branchproof/decision_table"
  autoload :Minimizer, "branchproof/minimizer"
  autoload :Report, "branchproof/report"
  autoload :CoverageIndex, "branchproof/coverage_index"
  autoload :FocusedReport, "branchproof/focused_report"
  autoload :SavedReport, "branchproof/saved_report"
  autoload :Comparison, "branchproof/comparison"
  autoload :ComparisonReport, "branchproof/comparison_report"
  autoload :Worker, "branchproof/worker"
end

MCDC = Branchproof unless defined?(MCDC)
