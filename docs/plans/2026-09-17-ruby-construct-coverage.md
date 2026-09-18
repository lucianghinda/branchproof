# Ruby construct coverage implementation plan

**Goal:** Exercise all 144 restored Ruby examples against Branchproof's supported discovery, instrumentation, coverage analysis, and reporting contracts.

**Architecture:** Keep the four native-semantics manifests as the behavioral oracle. Add explicit source expectations and a small test-only subprocess harness. Reuse captured evidence across analysis and rendering assertions rather than executing every combination of presentation options.

**Scope:** Tests for current support, including explicit unsupported and no-decision expectations. Adding new syntax support or the separately planned RSpec adapter is outside this change. No new dependencies. Preserve the stash and the original fixture syntax.

## Contract and evidence

- Native examples: `test/test_ruby_construct_examples.rb:8`, 144 IDs across 14 families and 406 execution cases; syntax and behavior checked separately.
- Boolean criteria: decision, condition, condition/decision, masking MC/DC, decision table (`README.md:130`). Alternative coverage for multiway, pattern and implicit decisions is separate (`README.md:545`).
- Levels 1, 2, 3 change presentation, not analysis (`README.md:407`). Views group by decision, condition, test, or decision table (`README.md:421`).
- Supported execution: serial Minitest in plain Ruby and Rails; CRuby 3.3/3.4 (`README.md:624`, `.github/workflows/main.yml`). RSpec remains a separately planned capability.
- Unsupported constructs must retain diagnostics and stay outside denominators (`README.md:575`). Ordinary predicate calls, optional argument binding, and method-defined selection do not automatically become decisions.
- Existing reusable patterns: `test/test_expanded_boolean_behavior.rb:314` for rewrite/run/evidence; `test/test_decision_expansion_acceptance.rb:11` for real CLI and offline reports; `test/test_coverage_ladder.rb:21` for exact coverage and provenance.

## Implementation tasks

- [x] **Source inventory:** Add `test/fixtures/ruby_constructs/expectations/source.json` and `test/test_ruby_construct_source.rb`. Explicitly enumerate every ID's ordered decision kinds, contexts, support statuses and exclusion reasons. Assert fixture/expectation bijection, locations/condition ordering and no duplicate nested Boolean inventory. Review observed inventories against documented support before recording expectations; never compute expected values using the production implementation during tests.
- [x] **Behavior and evidence:** Add `test/support/ruby_constructs.rb` and `test/test_ruby_construct_behavior.rb`. Execute every named case in a fresh child for instrumented source; compare with native manifests, preserving false/nil, exceptions, trace order and process exits. Capture executions separately from application stdout. Parent-enforced timeouts must kill/reap children even for exit/abort fixtures. Feed ordinary completed executions through real Evidence and Analyzer. Do not claim evidence completeness for abrupt process termination.
- [x] **Coverage analysis:** Add `test/test_ruby_construct_analysis.rb`. For every fixture with supported decisions, analyze its manifest cases using the shared harness; assert criterion applicability, denominator separation, owner provenance, unexecuted/aborted handling, and decision-table consistency. Add explicit, independently calculated vectors/counts and witness expectations for representative AND/OR, nested/negated, loops, pattern and implicit forms. Include partial input populations and reachability disabled; never require every native example to achieve full coverage.
- [x] **Levels, views and persistence:** Add `test/test_ruby_construct_reporting.rb`. Render every fixture's evidence at levels 1/2/3 and every legal view; check immutable analysis, stable denominator/status/diagnostic facts and detail appropriate to the level. Exercise saved-report round trips and identical/changed-population comparisons for representative Boolean, alternative, unsupported and empty inventories. Invalid option combinations should remain covered by existing CLI tests.
- [x] **Execution integration:** Add `test/test_ruby_construct_acceptance.rb` for real serial Minitest/CLI runs drawn from each relevant decision kind, attribution and lifecycle phases, offline reopen and selected Rails loading integration where available. Reuse fixture cases without loading multiple colliding `example` methods into one scope. Plain calls and unsupported-only fixtures must have explicit expected non-success/no-scope behavior where required by the CLI contract.
- [x] **Documentation and verification:** Explain the distinction between native behavior and Branchproof support in the fixture README. Run new suites on CRuby 3.3.6 and 3.4.5; run full tests and RuboCop; run the optional Rails job if its dependencies are available. Record environmental blockers without changing dependency locks. Review specification compliance, then code quality, and correct findings.

## Acceptance criteria

1. All 144 IDs are accounted for exactly once in static expectations and every original named case runs against rewritten or unchanged source.
2. Supported Boolean decisions exercise all five criteria; alternatives never inflate Boolean denominators; unsupported/no-decision cases cannot become false coverage success.
3. Every fixture is exercised at all presentation levels and legal views using its captured evidence, with analysis unchanged by rendering.
4. Exact semantic anchors detect dropped observations, incorrect short-circuit skips, wrong outcome selection, misplaced provenance and lost exclusions; broad generated checks supplement these anchors.
5. Real adapter/CLI tests prove execution and persistence boundaries; Rails-specific tests retain the optional dependency gate.
6. Tests preserve native values, ordering, exceptional/nonlocal control flow, and terminate safely with no leaking runtime context.
7. No production changes without a failing regression demonstrating the need; no unrequested dependency or syntax-support expansion.

## Risks and mitigations

- **Self-fulfilling snapshots:** Review source expectations and use manually reasoned exact vector/coverage anchors.
- **Runtime cost:** Capture once per fixture per suite and reuse across level/view assertions; isolate cases where globals and process termination demand it.
- **Fixture side effects:** Fresh child processes; dedicated evidence transport and bounded process lifetime.
- **Unsupported versus absent decisions:** Explicit source inventory distinguishes excluded decisions from ordinary expressions with no inventory entry.
- **Local tooling:** Default shell Ruby is 2.6 with inherited Ruby 4 gem paths. Select CRuby explicitly and isolate GEM_HOME/GEM_PATH. Locked development gems are not all installed; direct test execution with installed supported dependencies is a fallback, not a claim of locked-bundle validation.

## Implementation findings

- Source expectations cover all 142 IDs, 175 decisions, 26 excluded decisions, and 35 no-decision fixtures. Exact byte ranges and line/column locations distinguish repeated operands.
- The shared helper caches subprocess observations, keeping the native manifests as the independent behavior oracle. It checks evidence merges, preserves stable case owners, and marks process termination incomplete.
- The corpus exposed invalid rewriting of bare logical control transfers (`ready or return`, `value && break`). `Instrumenter#condition_wrapper` now wraps those operands in `begin`/`end` without recording an invented condition value; frame unwinding records aborted decisions. Regression tests cover valued transfers and compilation of `next`, `redo`, and `retry` with syntax accepted on both supported Ruby lines.
- Reporting checks all levels/views against captured counts, explicitly verifies missing-only filtering, and round-trips all saved documents. CLI tests exercise each supported decision context, and Rails embeds the actual CASE-02 fixture inside a namespaced Zeitwerk service in lazy/eager modes.
- No dependencies or lockfile changes. Source and runtime implementation received separate specification and quality reviews using Luna agents.

## Verification baseline

Restored native harness passes on CRuby 3.3.6 and 3.4.5: 543 tests, 2,031 assertions, zero failures/errors/skips on each. The latter run disables unrelated globally installed Minitest plugins. Stash applied cleanly and retained.

## Final verification — 2026-09-17

- CRuby 3.3.6, Minitest 5.x and Prism 1.x explicitly selected: full suite **1,392 tests, 215,639 assertions, zero failures/errors**, five optional Rails skips.
- CRuby 3.4.7, frozen locked bundle, `bundle exec rake test`: full suite **1,392 tests, 215,639 assertions, zero failures/errors**, five optional Rails skips.
- Rails integration enabled on CRuby 3.4.7: all five integration tests pass. The final CASE-02-based lazy/eager test was also rerun after replacing the initial hand-written service, with **42 assertions** passing.
- Locked RuboCop 1.90: **105 files, zero offenses**. `git diff --check` passes.
- The original native-only validator also passed independently on CRuby 3.3.6 and 3.4.5: 543 tests and 2,031 assertions per runtime.
- Final specification review approved source, analysis, reporting and execution contracts; separate quality review found no blocking production issue. Its missing-only filtering suggestion is covered by an explicit condition/rule removal test.

Implementation was prepared on `test/ruby-construct-coverage`. The original stash is retained. No dependency, lockfile, or production support-scope changes were made; the instrumentation correction restores already-supported nonlocal logical control flow.

## Current corpus completion — 2026-09-18

The catalog now contains 144 fixtures and 406 native cases. Static expectations
cover 285 decisions across 143 decision-bearing fixtures; `PRED-15` remains an
intentional no-decision fixture because eager integer bitwise results do not
have a meaningful false/truthy domain. This supersedes the earlier corpus
population for current verification; the 2026-09-17 counts above remain the
historical baseline for that run.

The RC-04 follow-up removes unreachable bitwise alternatives, while RC-05 keeps
value coverage enabled by default and caches repeated evidence without changing
counts, test/phase attribution, or saved-report semantics. RC-02 and RC-03
regressions cover transfer-safe exception paths and nested/deferred iterator
callbacks. The remaining review follow-up is the documented exception `else`
body with a nonlocal transfer, which still needs a production fix before its
acceptance case can be marked complete.
