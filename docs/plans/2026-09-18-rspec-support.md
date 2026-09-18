# RSpec support implementation plan

> Implementation authorized by the user on 2026-09-18, on a new branch using Luna subagents. The execution record below supplements the original acceptance checklist.

**Goal:** Run serial RSpec suites in both plain Ruby and Rails projects in the first release, with the same measurable Ruby constructs, ownership evidence, coverage criteria, report levels, views, saved reports, and comparisons as Minitest.

**Architecture:** Project resolves framework policy separately from Ruby/Rails project kind. Worker dispatches to a dedicated RSpec adapter within the existing isolated process. For RSpec/Rails, the application's helper owns Rails boot after the loader is installed; shared Rails validation enforces the test environment and disabled reloading without loading Minitest's `rails/test_help`. The adapter translates example lifecycle events into existing Runtime/Evidence records; discovery, instrumentation, and coverage criteria stay framework-neutral.

**Tech stack:** Existing CRuby 3.3/3.4 matrix and Prism; initially RSpec 3.13.x, characterized against installed rspec-core 3.13.6. Rails integration targets the existing Rails 8.1 / CRuby 3.4 job. Test rspec-rails 8.x as the initial compatibility candidate and lock a verified patch with compatible RSpec components before claiming that matrix. Applications supply RSpec and rspec-rails at runtime. Proposed development/integration-only dependencies include RSpec, rspec-rails, SQLite for transactional fixtures, and Capybara for in-process feature/system tests. No dependency changes are part of this planning task.

**Status:** Implemented on `feature/rspec-support`, based on main at `ea2a75f` after PR #7 merged. Plain Ruby and rspec-rails are delivered together. Version remains 0.9.0. Compatibility verification is recorded below.

## Relationship to previous drafts

This plan supersedes the implementation guidance in workspace `docs/2026-09-17-rspec-adapter-design.md` and `docs/2026-09-17-rspec-adapter-implementation-plan.md` for the next iteration. Preserve them as historical design input. Their Project-based policy and separate adapter remain useful, but do not copy their implementation verbatim:

- Minitest runs asynchronously at process exit; RSpec's runner returns synchronously. Worker must account for both.
- `Example#run` alone misses examples failed/skipped by context hooks; use reporter notifications for terminal status reconciliation.
- Inspect effective RSpec options, including option files and `SPEC_OPTS`, before dispatching a custom runner. Raw CLI argument rejection is insufficient.
- Comparison currently requires Minitest class/method identity; RSpec needs its own matching key.
- The old plain-Ruby-only boundary is superseded. Rails boot, transactional fixtures, spec-type integration, and Rails CI are required for this release.
- Do not inherit old instructions to start from pre-PR-7 main, change the version, regenerate release artifacts, or use a different author's co-author trailer. Commits follow current Lore rules.

## First-release contract

### User experience and scope

```sh
bundle exec branchproof analyze 'lib/**/*.rb' --framework rspec
bundle exec branchproof analyze 'lib/**/*.rb' --framework rspec -- --seed 1234 --tag fast
bundle exec branchproof analyze 'lib/**/*.rb' --framework rspec --test spec/access_spec.rb -- -e 'allows access'
bundle exec branchproof analyze 'app/**/*.rb' --project rails --framework rspec -- --seed 1234
```

- Add `--framework auto|minitest|rspec`, default auto. Resolve after parsing all options so `--project` and `--framework` order cannot change behavior.
- Auto markers: `.rspec` or `spec/**/*_spec.rb` for RSpec; current Minitest test globs for Minitest. Both sets require explicit selection; no markers preserves the Minitest default.
- RSpec defaults: `lib` and `spec` load paths; `spec/**/*_spec.rb` discovery. Helpers, support, and fixtures are not automatically selected as spec entry files. Explicit `--test` remains authoritative.
- RSpec handles ordinary configuration, helper requires, tags, descriptions, ordering, fail-fast, mocks, expectations, shared examples, shared contexts, `let`, `let!`, and subjects.
- Initial release supports serial plain Ruby and rspec-rails suites. Detect and reject dry-run, bisect, DRb, custom/repeated runners, and known parallel worker modes with actionable diagnostics. Do not claim detection of arbitrary custom schedulers.
- Rails auto-detection uses the existing application/environment markers independently of framework detection. Rails/RSpec is a supported combination. If `--project ruby` is explicit but helpers boot Rails, report a project-policy mismatch with guidance to use `--project rails`; do not silently skip Rails validation.
- Rails spec coverage includes model, request, controller, routing, helper, view, mailer, job, channel, and in-process feature/system specs. Browser/remote-server modes requiring another execution context are outside the existing serial attribution contract; give an actionable unsupported-mode diagnostic rather than claiming complete attributed coverage. This is a driver/execution limitation, not a blanket exclusion of system specs.
- No version bump, release publication, Rake task, new output format, retry-plugin support, or parallel evidence merging in this feature.

### Identity and attribution

Test records retain existing keys and add optional `example_id`. Use RSpec's scoped example ID plus normalized source location and adapter name to derive identity; never use full description as the unique key. Full description is the display label, refreshed after execution for generated descriptions. Duplicate descriptions and shared examples must remain distinct.

| Execution | Attribution |
| --- | --- |
| Around-hook code before yielding; before-example hooks; eager `let!` | Example, setup |
| Example body; lazy `let`/subject evaluated there | Example, body |
| After-example hooks; mock verification/cleanup; around-hook code after yielding | Example, teardown |
| Suite and context hooks, including filtered/singleton context hooks | Unattributed; never charged to an arbitrary example |
| Spec definition/helper loading outside examples | Unattributed |
| Lazy helper evaluated in a hook | Phase of actual evaluation |
| Application-created thread/fiber | Existing Runtime behavior; no new context propagation |
| Rails fixture creation, transactional setup, framework before hooks | Example, setup, verified against the actual rspec-rails lifecycle |
| Synchronous requests, model callbacks, mailer work, jobs performed inline | Phase of the invoking example/hook |
| Transaction rollback, fixture cleanup, framework after hooks | Example, teardown |
| Rails initializers/eager loading during boot | Unattributed |

Always clear/restore context in ensure paths. A decision already entered retains its entry context under the existing Runtime contract. Explicitly test around hooks that raise before/after yielding or never yield. Repeated execution of one example through retry/around plugins is outside the initial contract; diagnose it rather than silently merging attempts.

Evidence owns observation phase counts. Do not overwrite them with adapter lifecycle-transition counts. RSpec final test records must preserve the evidence counts; avoid broad changes to the existing Minitest adapter in this feature.

### Outcome and completeness

- Map actual RSpec execution status: passed → passed; failed → failed; pending/skipped → skipped. A pending example that unexpectedly passes remains failed.
- Terminal reporter events reconcile examples that never enter `Example#run`, such as a before-context failure/skip. Recording their status must not invent body execution or ownership.
- Include non-example failures from loading, configuration, suite/context cleanup, and runner state in baseline classification. Zero failed example records is not sufficient for PASSED.
- Preserve the native runner exit status in baseline metadata while retaining Branchproof's public CLI contract: successful analysis 0, test failure 1, unsupported/incomplete/error 2. Test custom RSpec failure exit codes and zero-valued failure exit configuration so neither can hide failed examples.
- Empty selection is INCOMPLETE. Dry-run is rejected. All-skipped selection follows existing Minitest baseline behavior, with zero fabricated observations.
- Fail-fast retains actual failed/executed records and never produces successful complete analysis. A normally filtered successful run is complete for its recorded selection, not the unselected suite.
- Finalize exactly once after runner and suite cleanup return. Abrupt termination, callback failure, loader error, or late process failure cannot leave a trustworthy PASSED report.

## Code map and implementation sequence

Paths below are relative to `gems/branchproof`; line references describe the inspected base and may move.

### 1. Establish RSpec lifecycle contracts before choosing hooks

Files: create `test/test_rspec_lifecycle_contract.rb` and `test/fixtures/rspec/`; development dependency in `Gemfile`/lockfile when implementation is authorized.

- [ ] Add isolated subprocess fixtures that emit an ordered lifecycle trace for nested before/after/around hooks, body, lazy/eager helpers, context hooks, mocks, pending-fixed, and exceptions.
- [ ] Compare native RSpec results to expected status, ordering, and runner exit behavior. Include context-failed/skipped examples that bypass `Example#run` and errors outside examples.
- [ ] Establish tests for one run with `rspec/autorun`, no body execution in dry-run, duplicate descriptions, and shared-example identity.
- [ ] Select minimal hooks using this evidence: public reporter notifications for test registration/final statuses; a small version-scoped prepend around example execution and before/after boundaries for phase changes. Explicitly bracket context hooks if they execute inside the example boundary.
- [ ] Keep the hook compatibility contract constrained to 3.13.x and test the lower supported patch and current installed patch in isolated bundles.

Native sources to inspect: `RSpec::Core::Example#run`, `#fail_with_exception`, `#skip_with_exception`, `#run_before_example`, `#run_after_example`; ExampleGroup context-hook execution; Runner finalization. Avoid copying RSpec's entire execution method.

### 2. Add framework selection and correct selection metadata

Files: `lib/branchproof/project.rb:15`, `lib/branchproof/cli.rb:202,222,285,380`; tests `test/test_project.rb`, `test/test_cli.rb`.

- [ ] Add failing tests for the detection matrix, ambiguous roots, explicit overrides, reversed option order, Rails/RSpec selection, load paths, and default patterns. Include Rails apps containing both test and spec directories.
- [ ] Add `Project.new(root:, mode: "auto", framework: "auto")`. Its resolved hash carries `framework`, `test_patterns`, and framework-appropriate load paths. Keep kind independent of framework.
- [ ] Resolve policy once after CLI parsing; use it for defaults, exclusions, worker payload, and requested run metadata. Existing Minitest invocations must remain unchanged.
- [ ] Support RSpec tags/names/order from runner args. For positional RSpec path/line/example-ID selectors, replace default discovered entry files rather than unioning both. Reject an ambiguous combination of explicit `--test` and positional runner selectors with a usage error.
- [ ] Preserve both requested selection and resolved framework/version/seed plus actual selected example IDs. Resolve option-file selections consistently; never claim the default file population when RSpec ran a narrower one.
- [ ] Validate missing RSpec/unsupported version with specific diagnostics. Do not require RSpec when a Minitest project is analyzed.

### 3. Implement adapter and serial-runner validation

Files: create `lib/branchproof/rspec_adapter.rb`, add autoload at `lib/branchproof.rb:16`; create `test/test_rspec_adapter.rb`. Reuse `runtime.rb:87,96`, `evidence.rb:42`, and `Records.id`.

Public adapter contract:

```ruby
def initialize(runtime:)
def run(test_files:, runner_args:, on_complete:, before_load: nil)
def validate_runner!
attr_reader :tests
```

- [ ] Test records, IDs, all attribution/outcome rows above with real RSpec plus a small runtime spy. Run global-hook tests in subprocesses to avoid contaminating Branchproof's Minitest suite.
- [ ] Implement idempotent hook installation and per-run active state, clearing it in ensure. Suppress autorun and guard duplicate/reentrant native runner calls.
- [ ] Parse effective options with RSpec's option machinery before runner dispatch; validate CLI, `.rspec`, `.rspec-local`, global options, custom `--options`, and `SPEC_OPTS`. Avoid implementing a second options parser or parsing/applying requires twice.
- [ ] Guard bisect/DRb/custom runner selection before execution, and detect configured dry-run before examples. Validate rspec-rails/project-policy compatibility and reject known parallel worker environments and nested runner entry points.
- [ ] Implement phase changes and terminal-event reconciliation from step 1. Preserve return values/exceptions and exact native ordering. Completion callback fires once; its failure becomes a structured worker error.
- [ ] Finalize canonical test records using Evidence's phase counts and final labels/statuses. Assert repeated traces across two RSpec examples retain separate owners under the 0.9.0 evidence cache.

Do not introduce a general adapter registry or extract a shared base adapter merely because there are now two implementations.

### 4. Integrate synchronous execution into Worker

Files: `lib/branchproof/worker.rb:15,78,87,103`, `lib/branchproof/cli.rb:318,329`; `test/test_worker.rb`, create `test/test_rspec_acceptance.rb`.

- [ ] Lock current Minitest async behavior with existing tests, then add failing subprocess tests for synchronous RSpec completion and missing dependency.
- [ ] Replace hard-coded framework loading/adapter construction with explicit two-way dispatch. Missing framework in legacy payloads means Minitest. Only the Minitest path calls `Minitest.autorun`.
- [ ] Keep Runtime boot and Loader installation before application/helper/spec loading. Preserve stdout/stderr capture and atomic result/marker publication.
- [ ] Distinguish missing rspec-core from LoadError raised by application helpers. Classify non-example failures, completion failures, interrupted runs, and late process exit; preserve diagnostic severity and completeness behavior.
- [ ] Assert normal RSpec output/formatters cannot contaminate Branchproof JSON output, and helper/autorun combinations never execute examples twice.

### 5. Extend report metadata and owner comparison safely

Files: `lib/branchproof/report.rb:509,632`, `coverage_index.rb:268`, `saved_report.rb:640,724`, `comparison.rb:366,439,457`, `cli.rb:202`; corresponding existing test files.

- [ ] Add round-trip tests for nullable `example_id`, framework, framework version, Rails version, and rspec-rails version. Old reports without these fields still load. Keep schema 1.3 only after proving the extension is optional and compatible.
- [ ] Reuse full-description label fallback across every view; change baseline noun to examples for RSpec only. Do not add an RSpec formatter as a Branchproof output format.
- [ ] Implement an RSpec owner comparison key using adapter, normalized relative spec path, and scoped example identity; preserve the existing Minitest key. Do not match on description alone or absolute checkout path.
- [ ] Test repeat runs, moved checkout roots, duplicate descriptions, repeated shared examples, and changed IDs/locations. Changed/ambiguous identity is contextual uncertainty, not fabricated lost proof.
- [ ] Include framework/version and effective selection in comparison context. Cross-framework runs must not produce an unconditional regression gate from mismatched owners. Older reports with unknown framework remain readable; infer only when recorded adapter data is unambiguous.
- [ ] Keep source decision IDs, alternative denominators, Boolean criteria, and evidence serialization semantics unchanged.

### 6. Integrate Rails boot and spec lifecycle in the same release

Files: `lib/branchproof/rails_support.rb:12,32,39`, `worker.rb:34,67`, `project.rb:7`; create `test/test_rspec_rails_integration.rb` and `test/fixtures/rspec_rails_app/`; retain `test/test_rails_integration.rb` unchanged as the Minitest regression gate.

Before changing the shared Rails boundary, lock existing Minitest boot behavior. Reuse its validation/metadata methods; separate framework-specific helper loading with the smallest change, without adding a second Rails boot abstraction.

- [ ] Provision an isolated Rails 8.1 / Ruby 3.4 / rspec-rails integration bundle and pin a passing compatibility tuple. Run native RSpec against the fixture before enabling Branchproof; do not assume rspec-rails compatibility solely from its major version.
- [ ] Build a dedicated fixture app with Active Record and an ephemeral SQLite database, routes/controller, model, service, job, mailer, view/helper, and channel. Keep database creation/schema setup outside measured example phases; never use an application developer's database for integration tests.
- [ ] Install Runtime/Loader before RSpec option `--require`, `spec_helper`, `rails_helper`, initializers, or eager loading. Let the project's helper require `config/environment` and `rspec/rails` in its native order. Do not additionally call the current `RailsSupport.boot_environment`, which unconditionally requires `rails/test_help`.
- [ ] Validate Rails initialization, test environment, supported version tuple, and disabled reloading after helper loading and before application examples execute. Also validate before instrumented application work can be accepted as complete evidence. Missing boot/helper dependencies, initialization failures, or environment mismatches produce diagnostics and non-successful reports.
- [ ] Preserve existing test-environment, Bootsnap/Spring, and serial-process policy before boot. Assert application/helper initialization occurs exactly once for both `--require rails_helper` and per-spec `require "rails_helper"`, with no Minitest autorun or `rails/test_help` introduced by Branchproof.
- [ ] Run lazy and eager Zeitwerk modes, including namespaced services, and verify exact generated decision probes and attribution. Confirm no application source files are modified.
- [ ] Cover every in-scope spec type with real native-versus-instrumented examples. For jobs use the test adapter and inline `perform_enqueued_jobs`; for feature/system specs use an in-process Rack driver. Reject configured remote/threaded browser-server execution before it can yield a misleading successful coverage report.
- [ ] Verify transactional isolation by writing in one example and observing no leaked records in the next. Include rollback after assertion failure and before/after hook failures. Assert exact setup/body/teardown vector ownership for model callbacks and framework cleanup; do not infer phase correctness from passing transactions alone.
- [ ] Cover filters/seeds, duplicate/shared examples, pending/skip, request failures, suite-hook failures, boot errors, reloading rejection, and unsupported driver diagnostics. Verify no example-context leakage between spec types.
- [ ] Add Rails report round trips, all report levels/views on representative model/request/service decisions, and repeated Rails comparisons. Capture actual Rails and rspec-rails versions in metadata; changed framework versions remain comparison context.

### 7. Prove parity across the full measurable corpus and report surface

Files: `test/support/ruby_constructs.rb`, existing `test/fixtures/ruby_constructs/` manifests; create `test/test_rspec_constructs.rb`; extend `test/test_rspec_acceptance.rb`.

- [ ] Reuse all **144 fixtures / 406 native cases**, including decision-free PRED-15. Generate isolated RSpec examples from existing data; do not duplicate source fixtures or replace the Minitest harness.
- [ ] Match expected native results, exceptions, and side effects. Compare normalized inventory, vectors, alternatives, and proof statuses to existing framework-neutral expectations, excluding expected framework IDs/timing differences.
- [ ] Verify **285 decisions across 143 decision-bearing fixtures** on the current baseline. If baseline changes legitimately, reconcile exact counts deliberately rather than relaxing assertions.
- [ ] Exercise a representative end-to-end application across levels 1/2/3 and every supported view, terminal/JSON restrictions, missing-only where valid, saved-report rendering without execution, and same/cross-framework comparison. Run every construct through RSpec once; avoid multiplying all 406 cases by every presentation option.
- [ ] Assert setup/body/teardown and unattributed evidence explicitly, including an around-hook wrapper and cached repeated observations owned by different examples.
- [ ] Assert expected CLI exit codes for every failure/completeness category and that all-skipped or filtered-empty suites cannot fabricate covered decisions.
- [ ] Run the same construct corpus through an isolated Rails/RSpec service fixture as well as plain Ruby, preserving fixture isolation and exact expectations. Cover all cases in lazy loading and a representative nested/transfer/default subset in eager mode; step 6 separately validates every Rails spec-type integration.

### 8. Documentation, compatibility gates, and delivery

Files: `README.md`, `CHANGELOG.md`, `branchproof.gemspec` description, `sig/branchproof.rbs`, `.github/workflows/main.yml`; preserve release-generated `doc/` and `llms.txt` policy.

- [ ] Document detection/ambiguity, installation, supported versions, example IDs, hook attribution, selector precedence, exclusions, and limitations; add RBS adapter/project signatures.
- [ ] Run focused tests after each implementation slice, then the full CRuby 3.3/3.4 suite, RuboCop, docs generation, signature validation, existing Rails/Minitest integration, and new Rails/RSpec integration. Both Rails jobs must run without optional-test skips before release.
- [ ] Measure native RSpec versus Branchproof-RSpec and equivalent Branchproof-Minitest fixtures: elapsed time, allocations, decisions, vector counts, and owners. Record results; investigate any change to the existing rewrite benchmark because this adapter should not alter instrumentation.
- [ ] Add RSpec compatibility jobs/bundles for the supported patch range and a required Rails/RSpec job on Rails 8.1 / Ruby 3.4, without adding runtime dependencies. Pin/report the verified rspec-rails tuple. No unsupported version is silently treated as supported.
- [ ] Start implementation on a separate feature branch from PR #7's reviewed head (or main after it contains those commits). Do not stack unrelated feature code into the construct-coverage PR. Use Lore commits and publish only after implementation is requested.

## Verification commands

In `gems/branchproof` with its supported Ruby/bundle, after adding the proposed development test dependency:

```sh
bundle exec ruby -Itest test/test_rspec_lifecycle_contract.rb
bundle exec ruby -Itest test/test_rspec_adapter.rb
bundle exec ruby -Itest test/test_rspec_acceptance.rb
bundle exec ruby -Itest test/test_rspec_constructs.rb
bundle exec rake
bundle exec rubocop --no-server --cache false
BRANCHPROOF_RAILS_INTEGRATION=1 bundle exec ruby -Itest test/test_rails_integration.rb
BRANCHPROOF_RSPEC_RAILS_INTEGRATION=1 bundle exec ruby -Itest test/test_rspec_rails_integration.rb
bundle exec rake docs
git diff --check
```

Expected: no failures/errors, no lint offenses; both Rails test suites actually execute in their integration bundles. `BRANCHPROOF_RSPEC_RAILS_INTEGRATION` is a new test-harness flag to add, not an existing application option. Separate Ruby files above are separate commands because `ruby file1.rb file2.rb` does not run two test files. CI must provision each integration bundle, not count skips as Rails verification.

## Risks and mitigations

| Risk | Mitigation / release gate |
| --- | --- |
| Private RSpec lifecycle methods change | Narrow version range; real characterization fixtures; supported-version CI; clear unsupported-version diagnostic |
| A hook/load error looks like a passing run | Reconcile runner state plus reporter statuses and native exit status; explicit non-example failure fixtures |
| Around/context execution is attributed to the wrong example | Ordered traces and exact vector ownership assertions, including singleton contexts and ensure paths |
| Configuration bypasses serial guards | Validate merged options before dispatch, revalidate effective config before execution, test each option source |
| Owner matching invents regressions | Framework-specific identity; normalized paths; conservative uncertainty on ID drift and legacy metadata |
| Phase counts are overwritten at final registration | Treat Evidence counts as canonical; check exact counts before/after completion and saved-report round trip |
| A second framework changes existing Ruby coverage | Full shared construct corpus and unchanged Minitest acceptance tests; no instrumentation changes planned |
| Rails boots before instrumentation or loads Minitest helpers | Loader-before-helper ordering, helper-owned boot, exactly-once counters, explicit loaded-feature assertions |
| Transaction hooks bypass attribution or leak database state | Native-versus-instrumented model fixtures, exact phases, rollback/isolation assertions after failures |
| System/browser server runs outside example context | In-process driver coverage and explicit rejection tests for unsupported remote/threaded modes |
| Nominally compatible framework versions fail together | Dedicated locked integration bundle and required Rails/RSpec CI; publish only the verified tuple |

## Release acceptance matrix

| Environment | Required evidence before the first release |
| --- | --- |
| Plain Ruby, CRuby 3.3 and 3.4, supported RSpec 3.13 patches | Lifecycle, CLI, full construct corpus, all report levels/views, saved reports and comparisons |
| Rails 8.1, CRuby 3.4, verified rspec-rails/RSpec tuple | Native parity, lazy/eager boot, all in-scope spec types, transactions, full corpus through Rails service fixtures, report/comparison parity |
| Existing Minitest plain Ruby and Rails environments | Full regression suites and unchanged boot/attribution behavior |
| Unsupported execution modes | Actionable diagnostics, non-successful exit, no falsely complete evidence |

Implement the common adapter before the Rails integration, but deliver them as one feature. A green plain Ruby suite alone does not satisfy this plan. Broader Rails versions and remote-browser context propagation can follow separately; rspec-rails itself cannot be deferred.

## Execution lanes

One owner first establishes lifecycle, metadata, and Rails boot contracts. After those are fixed, independent agents can own Project/CLI, adapter/Worker, reports/comparison, and Rails fixtures/validation. The Worker owner integrates the Rails lane's boot changes to avoid concurrent edits. Corpus acceptance and final review follow integration; both plain Ruby and Rails are required. Planning does not start these implementation lanes.

## Reference evidence

- Current adapter lifecycle and completion: `lib/branchproof/minitest_adapter.rb:16,58,118,132,151,202`.
- Worker ordering/finalization: `lib/branchproof/worker.rb:15,27,34,43,87,103`; parent reconciliation: `lib/branchproof/cli.rb:329`.
- Runtime context snapshot/registration: `lib/branchproof/runtime.rb:38,87,96,130,139`.
- Comparison identity and context: `lib/branchproof/comparison.rb:366,372,439,457`.
- Existing adapter acceptance matrix: `test/test_cli_acceptance.rb:14,42,50,65,85,120,136,152,196,264,303,331`.
- Current Rails boot/helper coupling: `lib/branchproof/rails_support.rb:12,32,39`; existing real Rails acceptance: `test/test_rails_integration.rb`; supported repository CI target: `.github/workflows/main.yml`.
- Upstream [rspec-rails compatibility guidance](https://github.com/rspec/rspec-rails) and [system-spec driver configuration](https://rspec.info/features/7-0/rspec-rails/system-specs/system-specs/). These inform the test matrix; they do not replace verifying the exact Rails 8.1 dependency tuple.
- RSpec upstream [Example lifecycle](https://github.com/rspec/rspec-core/blob/v3.13.0/lib/rspec/core/example.rb), [Runner](https://github.com/rspec/rspec-core/blob/v3.13.0/lib/rspec/core/runner.rb), and [configuration options](https://github.com/rspec/rspec-core/blob/v3.13.0/lib/rspec/core/configuration_options.rb). Also inspected installed 3.13.6 source, including `example.rb:246,439,449,503,516`, `runner.rb:64,194`, and `configuration_options.rb:44,126,134`.


## Implementation record — 2026-09-18

The feature is implemented on `feature/rspec-support` in an isolated worktree,
using Luna implementation and review agents. The original checklist above is
retained as the design record; the checks below describe executed verification.

- Framework selection is independent of Ruby/Rails project selection. The worker
  loads only the selected adapter, installs instrumentation before application
  helpers, and delegates RSpec option parsing and execution to the native runner.
- A dedicated serial adapter preserves scoped example identity, native status,
  setup/body/teardown ownership, unattributed context hooks, and canonical
  evidence counts. Repeated, nested, and late `at_exit` runners invalidate the
  report even when application code rescues their exceptions. Configuration is
  rechecked before examples to catch dry-run enabled by suite hooks.
- Reports keep the existing schema and test-count fields. RSpec changes display
  terminology, optional provenance, and owner matching, without changing source
  instrumentation or coverage denominators. Browser-backed Rails drivers are
  rejected before session launch; Capybara remains optional.
- The corpus covers 144 fixtures and 406 cases: 403 ordinary examples plus three
  isolated process-termination cases. It discovers 285 decisions in 143 fixtures;
  PRED-15 remains decision-free. Plain Ruby checks exact vectors, proof statuses,
  and alternative observations against the existing framework-neutral harness.
  Rails checks native/instrumented lazy/eager parity and all termination cases.
- Rails fixtures exercise model, request, controller, routing, helper, view,
  mailer, job, channel, feature, system, and service examples. Transaction tests
  check rollback after assertion, before-hook, and after-hook failures.
- Report acceptance covers all levels and views, saved rendering, filtering,
  repeated comparisons, and cross-framework context. Regression tests cover
  pending-fixed, skipped/empty selection, context/suite errors, fail-fast, custom
  native exit codes, shared examples, option sources, and autorun suppression.
- `bundle exec rake docs` succeeds; generated release documentation was restored
  to keep this change focused on source documentation. RBS parsing succeeds with
  RBS 3.6.1 on Ruby 3.3.6. RuboCop reports no offenses. The reproducible benchmark
  and measured process boundaries are in `docs/benchmarks/rspec-adapter.md`.

The supported first-release boundary remains serial RSpec 3.13.x, with
Rails 8.1.x / rspec-rails 8.x on Ruby 3.4.x. Arbitrary custom schedulers,
retry plugins, and remote browser attribution are outside this implementation.
No release was published and the gem version remains 0.9.0.


### Executed verification

| Check | Result |
| --- | --- |
| CRuby 3.4.7 full suite, RSpec Core 3.13.6 | 1,521 tests, 228,312 assertions, no failures/errors |
| CRuby 3.3.6 full suite, RSpec Core 3.13.6 | 1,521 tests, 228,316 assertions, no failures/errors |
| Isolated Core 3.13.0 bundle on CRuby 3.4.7, including worker subprocesses and full construct corpus | 26 tests, 2,648 assertions, no failures/errors/skips |
| Rails/RSpec integration and corpus, Rails 8.1.3.1 / rspec-rails 8.0.4 | 10 tests, 153 assertions, no failures/errors/skips |
| Existing Rails/Minitest integration | 5 tests, 122 assertions, no failures/errors/skips |
| Plain Ruby corpus proof/vector parity | 2 tests, 2,417 assertions, no failures/errors/skips |
| Final focused adapter/lifecycle/acceptance/safety/worker/report checks | Passing; additional dependency-diagnostic checks pass separately |
| RuboCop | 164 files, no offenses |
| RBS parser, documentation generation, gem build, diff whitespace check | Passing |

The 13 skips in each core full-suite run are the optional Rails checks;
those checks execute without skips in the dedicated integration bundles.
The gem build includes the RSpec adapter. CI now runs the two supported Ruby
versions, both Core patch endpoints, and separate Rails/Minitest and Rails/RSpec
jobs. Remote CI has not been run as part of this local branch implementation.
