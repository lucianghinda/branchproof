# Decision-table review and action register

Date: 2026-09-17  
Reviewed branch: `claude/decision-table-coverage-p6h9bx`  
Reviewed commit: `cd86353`  
Status: implementation and compatibility decisions completed; verification and limitations recorded below.

## Original review assessment

This assessment describes the original commit, before the fixes recorded at the end of this document.

Request changes before merge. The tree-derived table generator is a good foundation: it preserves short-circuit evaluation, retains separate condition occurrences, and overlays evidence from the existing test run. The principal blocker is that reachability analysis can remove executable rules from the coverage denominator. Performance and reporting defects are secondary but material for large projects and CI consumers.

This document consolidates:

- The [original decision-table requirements](../../../../docs/plan-for-decision-table.md).
- The Codex review in this conversation, including four Luna reviews and follow-up verification.
- Claude's “Decision Table Coverage Review”, dated 2026-09-17, supplied as `/Users/luciang/Downloads/Untitled.md`.
- A follow-up inspection of Claude's JSON regression and repeated-normalization findings.

The original evidence below refers to the reviewed commit. See the implementation record for the resulting behavior and verification.

## Reconciliation of the reviews

| Topic | Consolidated conclusion |
| --- | --- |
| “All 20 acceptance criteria are met” | Not established. False impossibility claims violate conservative reachability; the rule budget has a boundary defect; comparison ignores analysis versions. |
| Core Boolean generation | Both reviews agree it is structurally sound. Additional differential checking matched 200 seeded trees against Ruby traces over 39,432 assignments. |
| Integer/Float equality and rule limit | Independently identified by both reviews; confirmed defects. |
| Mutation, custom operators, NaN | Additional Codex findings. These affect the fundamental safety of excluding rules, beyond the mixed-numeric equality fix. |
| JSON regression flag | Additional Claude finding, confirmed by code inspection. The top-level flag omits decision-table-only losses that the CLI treats as regressions. |
| Largest overlay benchmark | Treat Claude's 4,096-rule/8,192-vector result as synthetic stress evidence, not a demonstrated ordinary decision under default limits. Evidence deduplicates observations, and generated rules constrain valid traces. Use the realistic measurements below for planning. |
| “Delete unused code without behavior change” | Too broad. Constants and helpers appear in RBS/generated API docs; fields appear in saved JSON. Lack of an internal reader does not establish compatibility safety. |
| Exhaustive truth tables | Original plan section 3 requests this capability; the branch implements reduced tables only. Explicitly defer it or add a bounded consumer-driven feature. It is unnecessary on the normal coverage path. |
| Reachability disabled mode | No user-facing option currently produces a calculated table with analysis disabled. The plan describes this conditionally, so classify it as a scope decision rather than an unambiguous missing acceptance criterion. |
| Covered → excluded comparison | May combine lost runtime evidence and changed analysis. Define the semantics rather than declaring every such transition solely an analysis change or solely a regression. |

## Prioritized actions

P1 means correctness or CI-contract work required before merge. P2 means reporting integrity or scaling work recommended before large-project use. P3 means bounded cleanup or an explicit scope decision. Each checkbox represents completed implementation plus its acceptance checks, not merely a proposed fix.

| ID | Priority | Action | Dependency |
| --- | --- | --- | --- |
| DT-01 | P1 | Establish conservative reachability boundaries | None |
| DT-02 | P1 | Correct numeric equality and unordered comparisons | DT-01 defines permitted domains |
| DT-03 | P1 | Enforce the exact rule budget | None |
| DT-04 | P1 | Align JSON regression reporting with CLI behavior | None |
| DT-05 | P2 | Replace the rule/vector cross product | Preserve DT-01/02 semantics |
| DT-06 | P2 | Make comparison version-aware | Coordinate with DT-04 |
| DT-07 | P2 | Validate saved decision-table evidence and summaries | DT-06 version policy |
| DT-08 | P2 | Keep uncalculated decisions visible in missing-only output | None |
| DT-09 | P2 | Remove measured repeated normalization/indexing | Baseline measurements first |
| DT-10 | P3 | Consolidate presentation and schema vocabulary | Correctness fixes first |
| DT-11 | P3 | Decide compatibility-sensitive deletions and payload changes | Consumer/schema audit |
| DT-12 | P3 | Resolve scope, terminology, and documentation gaps | DT-01 and DT-06 |

### DT-01 — Make impossibility claims conservative

- [x] Complete and verify.

**Evidence:** [constraints.rb:182](../../lib/branchproof/constraints.rb) normalizes comparisons by subject syntax; [decision_table.rb:145](../../lib/branchproof/decision_table.rb) accumulates constraints across the whole executable rule. Neither establishes that the subject's value remains stable or that comparison methods have built-in semantics.

This source is inventoried as supported, yet its executable all-true rule is excluded:

```ruby
x = 11
if x > 10 && (x = 0) && x < 5
  :yes
end
```

`0` is truthy. Equivalent failures were reproduced with an intervening method mutating `@x`, and an object whose `<` and `>` both return true.

**Action:** define the assumptions needed for a proof before expanding the solver. Keep reachability `unknown` when value stability or operator semantics cannot be established. Model writes/side effects conservatively; an unsupported atom must not allow unsafe constraints to flow through it. Do not treat a local-variable subject as proof of a numeric receiver. Prefer narrowing exclusions over adding a general symbolic engine. Any assumption-based mode must be explicit and must not present assumptions as unconditional proof.

**Acceptance:** source-to-table regressions retain the reachable rules for explicit local assignment, instance-variable mutation through a method, and custom comparisons. Tests show these rules remain coverage obligations without runtime evidence. Observed evidence still overrides genuine model conflicts and preserves attribution/diagnostics. Document which contradiction examples remain provable under the chosen policy.

### DT-02 — Respect Ruby numeric semantics

- [x] Complete and verify.

**Evidence:** [constraints.rb:289](../../lib/branchproof/constraints.rb) compares literal types before values; lines 65–68 complement false comparisons as if all numeric values were ordered.

- `x == 1 && x == 1.0` is satisfiable, but the all-true rule is excluded as conflicting equalities.
- With `x = Float::NAN`, `x < 0 || x >= 0` evaluates both conditions false. That executable rule is incorrectly excluded as conflicting bounds.

**Action:** support Ruby-compatible mixed numeric equality within the safe domain from DT-01; preserve distinct symbol/nil/Boolean semantics. Do not invert false inequalities into ordered bounds unless ordering is established. Avoid converting all numbers to Float, which loses large-integer precision.

**Acceptance:** cover Integer/Float equality and inequality in both literal orders, a large-integer precision boundary, NaN false-comparison paths, and ordinary contradictory bounds in the supported domain. Assert both rule reachability and denominator counts. No application expressions execute during static analysis.

### DT-03 — Enforce the exact rule limit

- [x] Complete and verify.

**Evidence:** [decision_table.rb:43](../../lib/branchproof/decision_table.rb) passes `max_rules + 1` and only checks for a nil result. A single atom with limit 1 returns two calculated rules; `a && b` with limit 2 returns three.

**Action:** enforce the actual budget, including atomic trees. Keep enumeration bounded while producing either a complete table or a clear `not_calculated` result.

**Acceptance:** test below/at/one-over limits for atoms and compound trees, plus the existing larger overrun case. Every successful table has `generated_rules <= configured_limit`; every exceeded limit returns the stable reason and no partial rules. Instrument a larger example to ensure rejection does not require exhaustive expansion.

### DT-04 — Align regression JSON and exit status

- [x] Complete and verify.

**Evidence:** [comparison.rb:84](../../lib/branchproof/comparison.rb) counts decision-table regressions separately but derives `regression` only from lost condition proofs. [comparison_report.rb:25](../../lib/branchproof/comparison_report.rb) also fails for decision-table losses.

**Action:** make the overall regression Boolean represent either criterion for complete comparisons. Preserve criterion-specific counts; explicitly document whether the existing `regressions` counter retains its old meaning or becomes an aggregate. Preserve incomplete-comparison exit semantics.

**Acceptance:** end-to-end comparisons cover rule-only loss, proof-only loss, both, neither, and incomplete context. JSON and `--fail-on-regression` agree; incomplete comparisons still exit 2. A rule-only loss must not require an MC/DC change to be reported.

### DT-05 — Classify each runtime vector once

- [x] Complete and verify.

**Evidence:** [decision_table.rb:162](../../lib/branchproof/decision_table.rb) scans every vector for every rule and checks condition positions again: worst-case `O(R × V × C)`.

Local Luna measurements used valid, unique traces and Ruby 4.0.1:

| Conditions | Rules / unique vectors | `DecisionTable.build` | Allocations |
| --- | ---: | ---: | ---: |
| 12, default | 377 | ~0.075 s | ~403,000 |
| 16, explicitly raised limit | 2,584 | ~3.375 s | ~17.8 million |

At 20 conditions, the default 4,096-rule cap rejected the tested shape in ~0.003 s. These are synthetic local measurements, not a whole-project SLA. Claude's timings used Ruby 4.0.6 and different workloads; do not compare them as equivalent runs.

**Action:** index generated rules and classify observations through the Boolean tree or an equivalent signature lookup. Preserve required-value and outcome matching; skipped conditions must not satisfy required values. Establish how malformed vectors are handled before assuming every input matches exactly one rule.

**Acceptance:** old/new implementations agree on coverage, rule IDs, attribution, vector IDs, unattributed counts, exclusions, and conflict diagnostics over generated trees and existing fixtures. With condition count held fixed, instrumentation demonstrates work proportional to rules plus vectors rather than their cross product. Benchmark typical three-condition decisions and the two valid workloads above on the same Ruby/machine; record time, allocations, and peak memory. No extra suite runs or dependencies.

### DT-06 — Compare compatible analysis contexts

- [x] Complete and verify.

**Evidence:** [comparison.rb:204](../../lib/branchproof/comparison.rb) indexes calculated rules without checking table or constraint-analysis versions. Changing persisted analysis version 1 to 999 yielded a complete, unchanged comparison with no context notice.

**Action:** define supported versions and compatibility separately for rule identity and reachability reasoning. Report version changes explicitly. Preserve comparisons that remain valid, but do not silently call incompatible analyses unchanged. Specify how simultaneous evidence and analysis changes are represented.

**Acceptance:** same-version comparisons retain behavior; different table versions cannot silently match incompatible identities; different solver versions produce a context/analysis notice. Test unknown → impossible, impossible → unknown, and covered → excluded transitions. Missing → impossible is not a coverage gain. Unsupported future versions receive a clear diagnostic or validation error according to the documented policy.

### DT-07 — Validate saved tables as coherent evidence

- [x] Complete and verify.

**Evidence:** [saved_report.rb:242](../../lib/branchproof/saved_report.rb) validates structure and some counts, but not all relationships. A report with `missing_rules: 999` and unchanged rules passes validation. Rule IDs are not recomputed.

**Action:** validate or derive missing counts, percentage, coverage status, and reachability-analysis state. Validate coverage/reachability consistency and that claimed evidence matches its rule. Recompute IDs for supported schemas, or reject versions whose identities cannot be validated. Keep validation structural and static; never load project code.

**Acceptance:** reject inconsistent counts/statuses, malformed percentages/flags, swapped IDs, and incompatible referenced vectors. Accept genuine excluded and runtime-overridden rules. Existing legacy schema fixtures and valid current round-trips continue to work. Cover zero-obligation and uncalculated tables without division or nil-handling regressions.

### DT-08 — Make missing-only limitations actionable

- [x] Complete and verify.

**Evidence:** [focused_report.rb:139](../../lib/branchproof/focused_report.rb) drops empty rule lists before checking calculation status. The aggregate warns about an uncalculated decision, but its expression, location, and reason disappear; output can end with “No missing decision-table rules.”

**Action:** retain uncalculated decision blocks independently of missing-rule filtering. Qualify any no-missing conclusion by the analyzed scope. Continue hiding impossible rules as missing obligations.

**Acceptance:** with a covered decision plus a limited decision, missing-only output shows the limited decision's location and stable reason. Test both condition and rule limits. Impossible-rule summaries remain visible, but excluded rules are not displayed as missing requirements.

### DT-09 — Remove repeated normalization and indexing

- [x] Complete and verify.

**Evidence:** repeated work is visible in [constraints.rb:46](../../lib/branchproof/constraints.rb), [coverage_index.rb:12](../../lib/branchproof/coverage_index.rb), [coverage_index.rb:121](../../lib/branchproof/coverage_index.rb), [comparison.rb:204](../../lib/branchproof/comparison.rb), and [report.rb:869](../../lib/branchproof/report.rb). Claude supplied additional timings; those individual timings have not been independently reproduced.

**Action:** measure and address one source at a time: normalize/validate constraints once per decision; avoid recopying already-normalized rules; build decision-table view rows lazily; reuse comparison indexes; memoize repeated report scans only where the inputs are immutable. Keep support for string-keyed saved JSON and symbol-keyed live records.

**Acceptance:** capture before/after allocations and elapsed time for each retained optimization. All report views and comparisons remain equivalent, repeated renders remain stable, and separate report instances do not share caches. Views not using table rows do not build them eagerly. Keep only changes with demonstrated benefit.

### DT-10 — Consolidate shared vocabulary and rendering

- [x] Complete and verify.

**Evidence:** [decision_table.rb:20](../../lib/branchproof/decision_table.rb), [saved_report.rb:14](../../lib/branchproof/saved_report.rb), [report.rb:13](../../lib/branchproof/report.rb), [focused_report.rb:8](../../lib/branchproof/focused_report.rb), and [comparison_report.rb:9](../../lib/branchproof/comparison_report.rb) repeat schema or display vocabulary. Percentage/default calculations also recur in Analyzer, DecisionTable, and Limits.

**Cleanup plan:** first preserve current semantic output with focused tests. Then make separate passes for enums/defaults, formatting helpers, and summary branching. Reuse existing boundaries; do not add a generalized presenter framework. Keep JSON field names and supported CLI spellings stable in this pass.

**Acceptance:** one authoritative definition per shared enum/default/display map; live and saved reports retain the same semantic content. Share requirement/reachability wording without forcing every view into identical layout. Simplify `missing_summary_line` only after tests cover its meaningful categories. Update RBS and generated docs for deliberate public changes.

### DT-11 — Audit deletions and report-size proposals before applying them

- [x] Complete compatibility audit and record decisions.

Claude identified useful candidates, but none should be deleted solely because `lib` has no reader. Public declarations include [sig/branchproof.rbs:117](../../sig/branchproof.rbs); JSON producers and validators form another contract.

| Candidate | Recommended disposition |
| --- | --- |
| Unused status constants | Reuse in validation first; remove only with corresponding API/docs decision. |
| Rule `index` | Check saved schemas and consumers; retain unless an explicit schema change removes it. |
| Aggregate `decision_percentage` | Keep the distinction between fully covered decisions and rule coverage. Render/document the metric or explicitly deprecate it. |
| Identity uppercase status map | Replace with shared formatting if output remains equivalent. |
| Single-caller wrapper | Inline only if it reduces complexity and does not break a supported public method. |
| `decision_tables` CLI alias | Prefer documenting/testing accepted behavior over silently removing it. |
| Duplicated source-change messages | Consolidate terminal wording while preserving machine-readable context. |
| `matched_rules` count | A convenience JSON aggregate may be useful; do not remove just because it is derivable. |
| `tests` versus `vector_ids` | Measure real report size first. Preserve offline attribution and evidence integrity; any compact format needs a schema/migration policy. |
| `status` / `table_status` naming | Improve internal naming first. A persisted rename requires compatibility handling. |

**Acceptance:** record retain/remove/defer for each candidate, including consumers checked and schema/API impact. Measure representative report bytes and load memory before approving payload changes. Valid previous reports remain readable. No field or supported spelling disappears as incidental cleanup.

### DT-12 — Resolve scope and user-facing semantics

- [x] Complete decisions, documentation, and relevant tests.

| Topic | Recommended action and acceptance |
| --- | --- |
| Exhaustive truth table | Defer explicitly in the original requirements and implementation docs unless a concrete consumer needs it. If retained, make it bounded and opt-in; keep it off the coverage hot path. |
| Reachability disabled mode | Decide whether to expose a calculated-table/no-exclusions mode, particularly while narrowing DT-01. If implemented, all generated rules remain obligations, reachability is reported as not analyzed, and comparison records the mode. Otherwise document the absence; do not delete the renderer branch without checking saved-report compatibility. |
| `unless` / `until` outcomes | Label the reported value as the predicate outcome where necessary. Add examples showing that a true predicate may skip the body. Keep runtime outcome semantics consistent. |
| README JSON | Label abbreviated examples or make them schema-complete. Do not delete evidence fields merely to match an abbreviated example. |
| Test fixture duplication | Share fixtures only where they describe the same scenario. Keep some exact alignment tests for a terminal table; use semantic assertions elsewhere. |
| Bare negated expressions | Document the existing inventory boundary; do not expand supported contexts as incidental work in this branch. |
| Future reachability statuses | Keep `user_excluded` and `runtime_unreachable_candidate` deferred. |

## Execution order and verification

1. Address DT-01 through DT-04 in small commits with failing regressions first. DT-01 is a semantic boundary decision, not a safe one-line cleanup.
2. Implement DT-05 with an equivalence oracle and repeatable Ruby benchmark. DT-06/07 should share the same schema/version decisions.
3. Complete DT-08, then make measured DT-09 optimizations.
4. Apply DT-10 smell by smell; record DT-11/12 decisions without bundling speculative API/schema changes into correctness fixes.

Independent work can proceed on rule limits, CI regression reporting, and terminal visibility. Coordinate edits to `decision_table.rb`, `constraints.rb`, and `comparison.rb` rather than assigning overlapping ownership. Do not introduce dependencies or rerun application tests per rule. Utility/benchmark scripts must use Ruby's standard library.

Verification evidence from the preceding review, on the unchanged reviewed commit:

- Full suite: 377 runs, 148,937 assertions, zero failures/errors; four optional Rails integration tests skipped.
- RuboCop: 91 files, zero offenses.
- `git diff --check origin/main...HEAD`: passed.
- Differential generator check: 200 seeded Boolean trees, 39,432 assignments matched actual Ruby short-circuit traces.
- Reproductions confirmed unsafe exclusions, rule-limit overrun, hidden per-decision limitations, ignored solver versions, and accepted inconsistent missing counts.
- JSON/exit regression mismatch and additional normalization opportunities were confirmed by code inspection; add executable regressions/benchmarks in their actions.

After implementation, run focused tests for each action, then the full `bundle exec rake` checks. Run the optional Rails integration job in its configured environment before claiming Rails verification. Update signatures/API documentation if public surfaces change; no standalone typecheck result was established in this review. Re-run representative performance measurements after the final integrated changes.

Completion requires passing checks, explicit resolution of the P1 actions, recorded disposition of the remaining actions, preserved offline evidence/compatibility, and an updated requirements checklist. A green existing suite alone does not establish conservative reachability or large-project suitability.

## Implementation record — 2026-09-17

All twelve actions are resolved by implementation or the explicit compatibility/scope decisions below. Luna subagents implemented independent lanes and performed subsequent specification and code reviews. Changes were developed in an isolated worktree to preserve concurrent work in the branch. No dependencies were added.

| Action | Result and regression coverage |
| --- | --- |
| DT-01 | Source constraints are trusted only for stable local truthiness in pure local/literal Boolean expressions; literal proofs remain available. Calls, writes, custom comparisons and overloadable negation cannot establish exclusions. `test_conservative_reachability.rb` covers executable counterexamples. |
| DT-02 | Exact mixed numeric equality avoids Float coercion; false inequalities do not assume total ordering. Nonfinite numeric literals cannot corrupt serialized constraints. Numeric regressions live in `test_constraints.rb` and conservative source tests. Source comparisons remain unknown without proof of receiver semantics. |
| DT-03 | Every successful enumeration respects the exact rule budget, including atoms. Boundary regressions are in `test_decision_table.rb`. |
| DT-04 | Complete comparison JSON reports either condition or table losses as regression. The existing `regressions` count remains condition-only; `decision_table_regressions` is separate. Incomplete comparisons retain exit 2. Contract tests cover the distinction. |
| DT-05 | Generated unique-occurrence tables use signature lookup. Malformed vectors and public overlapping-rule inputs retain generic matching behavior. Seeded differential and operation-count tests protect evidence and attribution equivalence. A repeatable benchmark is provided in `benchmark/decision_table.rb`. |
| DT-06 | Incompatible table schemas make comparison incomplete; supported solver-version and analysis-mode changes receive explicit context. Simultaneous exclusion and evidence loss retains both information streams. See `test_decision_table_comparison_contract.rb`. |
| DT-07 | Saved reports validate identities, indexes, labels, counts, percentages, statuses, versions and evidence relationships, including vector values/outcomes and attribution. Legacy reports without tables remain accepted. See `test_decision_table_validation.rb`. |
| DT-08 | Missing-only output retains uncalculated decisions with location/reason and qualifies its coverage conclusion. Presentation regressions cover limits and exclusion summaries. |
| DT-09 | Constraints are prepared once, table projections are lazy, already-normalized rules are reused, and report/comparison indexes are cached per instance. Existing live/saved reporting tests and new presentation tests protect behavior. |
| DT-10 | Shared labels/enums/defaults and requirement wording replace duplication; summary branching is simpler. RBS and generated API docs reflect deliberate public changes. |
| DT-11 | Compatibility audit completed with the dispositions below; no incidental persisted-field deletion or CLI spelling removal. Fully covered decision percentage is now rendered. |
| DT-12 | Added `--no-reachability`, documented predicate outcomes for `unless`/`until`, labeled abbreviated JSON, and reconciled both plans with the implemented scope. See `test_reachability_mode.rb` and presentation tests. |

### Compatibility and scope decisions

The audit checked library readers, CLI parsing, saved-report validation, RBS, generated API documentation and report tests.

- **Retain and reuse:** public status constants, `VALUE_LABELS` aliases and existing public wrappers. Shared authoritative definitions remove drift without deleting documented Ruby entry points.
- **Retain:** rule `index`, `matched_rules`, `tests`, `vector_ids`, and persisted `status`/`table_status`. These participate in ordering, summaries, offline attribution or saved schema contracts. A compact payload requires a separate versioned design.
- **Retain and expose:** `decision_percentage` means fully covered decisions, distinct from rule coverage; it now appears in output. Document and test the existing `decision_tables` CLI alias.
- **Retain:** separate source-change context entries and current terminal descriptions. They identify different condition/table comparisons; collapsing them needs a separate output-design decision. No duplicate machine context is silently discarded.
- **Defer explicitly:** exhaustive truth tables, `user_excluded`, `runtime_unreachable_candidate`, and expansion of bare-negation inventory contexts. Reduced executable tables fulfill the normal coverage workflow; exhaustive output needs a bounded consumer use case.
- **Keep scenario-specific fixtures:** independent counters and execution scenarios are not interchangeable. Share presentation vocabulary, but keep selected exact table alignment assertions and use semantic assertions for other output checks.
- **Implement optional analysis disablement:** `--no-reachability` keeps every generated rule as an obligation, including literal-impossible paths. Saved reports and comparisons disclose that analysis was disabled.

### Measurements and verification

Ruby 4.0.1 synthetic measurements on the same machine compare the new **whole table build** with the previous **matching loop alone**; they are not a whole-project SLA:

| Conditions | Unique vectors / rules | New build time / allocations | Previous matcher time / allocations |
| --- | ---: | ---: | ---: |
| 12 | 377 | 0.0102 s / 32,036 | 0.0704 s / 375,132 |
| 16 | 2,584 | 0.0601 s / 231,813 | 3.5144 s / 17,622,891 |

At 16 conditions this is about 58× faster and 98.7% fewer allocated objects, despite including more work in the new timing. Run `ruby -Ilib benchmark/decision_table.rb` to reproduce; timings vary.

A subsequent three-condition smoke measurement generated five rules: the whole build took 0.0013 s / 643 allocations versus under 0.0001 s / 72 allocations for matching alone. These sub-millisecond, unequal-work measurements do not establish a small-decision speedup; the optimization targets the growing rule/vector cross product.

A separate synthetic CoverageIndex projection benchmark (100 builds, each with 100 decision rows and forced table access) allocated 3,509,272 objects versus 5,500,154 before, a reduction of about 36%. This isolates projection overhead; it is not a validated full saved-report corpus. Its 87,486-byte sample would save only about 2.3% by dropping rule test IDs or 3.1% by dropping vector IDs, insufficient evidence for a schema change.

**Measurement limitations:** peak RSS could not be collected because the sandbox denied the timing utility's system query. No representative large-project corpus/load-memory benchmark was available. Per-optimization elapsed-time measurements were not isolated for every cache. Operation-count tests and aggregate allocation measurements establish the algorithmic improvements; peak memory and end-to-end large-project throughput remain follow-up measurements, not release guarantees.

- Ruby 3.3.6 core suite: 415 tests, 154,871 assertions, zero failures/errors; four optional Rails cases skipped. External Minitest plugin auto-loading was disabled to avoid unrelated locally installed plugin conflicts.
- Ruby 4.0.1 optional Rails integration: four tests, 100 assertions, zero failures/errors/skips.
- RuboCop: 98 files, no offenses in the isolated implementation.
- RBS signature validation and generated API documentation build passed.
- Seeded differential tests and focused regressions passed; final integrated branch checks are recorded below.

**Behavioral consequence:** some previously excluded comparison paths now count as missing because their impossibility was never proven. Coverage may decrease. Constraint-analysis version 2 and comparison context make this deliberate correction visible; do not restore unsafe exclusions merely to preserve the previous percentage.

### Final integrated branch verification

The isolated implementation was transferred into the working branch and verified byte-for-byte, preserving the pre-existing `.rubocop.yml` edits and concurrent Ruby construct fixtures/docs.

- Ruby 4.0.1 `bundle exec rake`: **958 tests, 156,908 assertions, zero failures/errors**; four optional Rails tests skipped by the default suite. RuboCop inspected **99 files with no offenses**. Existing fixture warnings and a temporary cache-path symlink warning did not affect the successful exit.
- Separate `BRANCHPROOF_RAILS_INTEGRATION=1` run: **4 tests, 100 assertions, zero failures/errors/skips**.
- RBS validation and `git diff --check`: passed in the integrated branch.
- The larger final test count includes the concurrently added Ruby construct examples. No commit, staging, or publication was performed.
