# frozen_string_literal: true

require_relative "branchproof/version"
require_relative "branchproof/records"
require_relative "branchproof/limits"
require_relative "branchproof/source"
require_relative "branchproof/project"

# Public namespace for source inventory and one-run MC/DC reporting.
module Branchproof
  class Error < StandardError; end
  autoload :CLI, "branchproof/cli"
  autoload :Instrumenter, "branchproof/instrumenter"
  autoload :Loader, "branchproof/loader"
  autoload :Runtime, "branchproof/runtime"
  autoload :MinitestAdapter, "branchproof/minitest_adapter"
  autoload :Evidence, "branchproof/evidence"
  autoload :Analyzer, "branchproof/analyzer"
  autoload :Minimizer, "branchproof/minimizer"
  autoload :Report, "branchproof/report"
  autoload :Worker, "branchproof/worker"
end

MCDC = Branchproof unless defined?(MCDC)
