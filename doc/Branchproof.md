# Module Branchproof <a id="module-Branchproof"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof.rb, lib/branchproof/cli.rb, lib/branchproof/limits.rb, lib/branchproof/loader.rb, lib/branchproof/report.rb, lib/branchproof/source.rb, lib/branchproof/worker.rb, lib/branchproof/project.rb, lib/branchproof/records.rb, lib/branchproof/runtime.rb, lib/branchproof/version.rb, lib/branchproof/analyzer.rb, lib/branchproof/evidence.rb, lib/branchproof/minimizer.rb, lib/branchproof/comparison.rb, lib/branchproof/constraints.rb, lib/branchproof/instrumenter.rb, lib/branchproof/runtime_flow.rb, lib/branchproof/saved_report.rb, lib/branchproof/value_syntax.rb, lib/branchproof/configuration.rb, lib/branchproof/rails_support.rb, lib/branchproof/rspec_adapter.rb, lib/branchproof/value_runtime.rb, lib/branchproof/coverage_index.rb, lib/branchproof/decision_table.rb, lib/branchproof/default_syntax.rb, lib/branchproof/focused_report.rb, lib/branchproof/decision_syntax.rb, lib/branchproof/default_runtime.rb, lib/branchproof/exception_syntax.rb, lib/branchproof/iteration_syntax.rb, lib/branchproof/minitest_adapter.rb, lib/branchproof/comparison_report.rb, lib/branchproof/exception_runtime.rb, lib/branchproof/iteration_runtime.rb, lib/branchproof/flow_instrumentation.rb, lib/branchproof/value_instrumentation.rb, lib/branchproof/default_instrumentation.rb, lib/branchproof/exception_instrumentation.rb, lib/branchproof/iteration_instrumentation.rb, lib/branchproof/extended_alternative_runtime.rb |

Keep source-boundary and parameter-binding rules together for auditing.
rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/MethodLength, Metrics/ModuleLength, Metrics/PerceivedComplexity

## Constants
### `VERSION` <a id="constant-VERSION"></a> <a id="VERSION-constant"></a>
Not documented.

# Documentation

- [Branchproof/Analyzer.md](Branchproof/Analyzer.md)
- [Branchproof/CLI.md](Branchproof/CLI.md)
- [Branchproof/Comparison.md](Branchproof/Comparison.md)
- [Branchproof/ComparisonReport.md](Branchproof/ComparisonReport.md)
- [Branchproof/Configuration.md](Branchproof/Configuration.md)
- [Branchproof/Constraints/Solver.md](Branchproof/Constraints/Solver.md)
- [Branchproof/Constraints.md](Branchproof/Constraints.md)
- [Branchproof/CoverageIndex.md](Branchproof/CoverageIndex.md)
- [Branchproof/DecisionSyntax.md](Branchproof/DecisionSyntax.md)
- [Branchproof/DecisionTable.md](Branchproof/DecisionTable.md)
- [Branchproof/DefaultInstrumentation.md](Branchproof/DefaultInstrumentation.md)
- [Branchproof/DefaultRuntime.md](Branchproof/DefaultRuntime.md)
- [Branchproof/DefaultSyntax.md](Branchproof/DefaultSyntax.md)
- [Branchproof/Error.md](Branchproof/Error.md)
- [Branchproof/Evidence.md](Branchproof/Evidence.md)
- [Branchproof/ExceptionInstrumentation.md](Branchproof/ExceptionInstrumentation.md)
- [Branchproof/ExceptionRuntime.md](Branchproof/ExceptionRuntime.md)
- [Branchproof/ExceptionSyntax.md](Branchproof/ExceptionSyntax.md)
- [Branchproof/ExtendedAlternativeRuntime.md](Branchproof/ExtendedAlternativeRuntime.md)
- [Branchproof/FlowInstrumentation.md](Branchproof/FlowInstrumentation.md)
- [Branchproof/FocusedReport.md](Branchproof/FocusedReport.md)
- [Branchproof/Instrumenter.md](Branchproof/Instrumenter.md)
- [Branchproof/IterationInstrumentation.md](Branchproof/IterationInstrumentation.md)
- [Branchproof/IterationRuntime.md](Branchproof/IterationRuntime.md)
- [Branchproof/IterationSyntax.md](Branchproof/IterationSyntax.md)
- [Branchproof/Limits.md](Branchproof/Limits.md)
- [Branchproof/Loader.md](Branchproof/Loader.md)
- [Branchproof/Minimizer.md](Branchproof/Minimizer.md)
- [Branchproof/MinitestAdapter.md](Branchproof/MinitestAdapter.md)
- [Branchproof/Project.md](Branchproof/Project.md)
- [Branchproof/RSpecAdapter/ClassRunnerGuard.md](Branchproof/RSpecAdapter/ClassRunnerGuard.md)
- [Branchproof/RSpecAdapter/ContextLifecycle.md](Branchproof/RSpecAdapter/ContextLifecycle.md)
- [Branchproof/RSpecAdapter/DefaultDiscovery.md](Branchproof/RSpecAdapter/DefaultDiscovery.md)
- [Branchproof/RSpecAdapter/ExampleLifecycle.md](Branchproof/RSpecAdapter/ExampleLifecycle.md)
- [Branchproof/RSpecAdapter/RunnerGuard.md](Branchproof/RSpecAdapter/RunnerGuard.md)
- [Branchproof/RSpecAdapter/UnsupportedRunner.md](Branchproof/RSpecAdapter/UnsupportedRunner.md)
- [Branchproof/RSpecAdapter.md](Branchproof/RSpecAdapter.md)
- [Branchproof/RailsSupport/Error.md](Branchproof/RailsSupport/Error.md)
- [Branchproof/RailsSupport.md](Branchproof/RailsSupport.md)
- [Branchproof/Records.md](Branchproof/Records.md)
- [Branchproof/Report.md](Branchproof/Report.md)
- [Branchproof/Runtime.md](Branchproof/Runtime.md)
- [Branchproof/RuntimeFlow.md](Branchproof/RuntimeFlow.md)
- [Branchproof/SavedReport.md](Branchproof/SavedReport.md)
- [Branchproof/Source.md](Branchproof/Source.md)
- [Branchproof/ValueInstrumentation.md](Branchproof/ValueInstrumentation.md)
- [Branchproof/ValueRuntime.md](Branchproof/ValueRuntime.md)
- [Branchproof/ValueSyntax.md](Branchproof/ValueSyntax.md)
- [Branchproof/Worker.md](Branchproof/Worker.md)
- [CHANGELOG.md](CHANGELOG.md)
- [README.md](README.md)
