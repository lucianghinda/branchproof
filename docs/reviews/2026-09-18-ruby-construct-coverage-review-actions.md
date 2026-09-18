# Ruby construct coverage review and action register

Date: 2026-09-18
Reviewed branch: `test/ruby-construct-coverage`
Reviewed commits: `4344ddc`, `bd8c97e` (base `main` at `d7cfba2`)
Status: RC-01 through RC-11 implemented and verified with Luna subagents; final verification and measurements are recorded below. The original findings and baseline measurements are retained as historical evidence.

## Original review assessment

Request changes before merge. The construct families are wired cleanly into the existing source, instrumentation, and runtime seams, the 400-case corpus checks native and instrumented behavior against the same expected values, and the focused suites do real differential `class_eval` checks. The suite is green: 1,422 runs, 219,820 assertions, zero failures, five optional Rails skips. RuboCop: 124 files, zero offenses.

Four confirmed defects block merge. Two are load-path failures on common Ruby (a crash and a silent loss of all instrumentation for a file). Two make the coverage report wrong (a false "empty" observation and a structurally unreachable alternative). Separately, the branch regresses the load-path invariants that the previous performance PR established (one walk, one splice, one compile) and multiplies runtime cost by instrumenting every `[]`, `?` predicate, `each`-style block, and default parameter as a fully recorded decision.

All findings were reproduced by running code on Ruby 3.4.7, not inferred from reading. Reproduction snippets are included inline so the implementer can turn each one into a failing regression first.

## Measurements on the reviewed commit

Same files and same Ruby on both sides. "Rewrite" means `Branchproof::Instrumenter#rewrite`, the call `Loader#load_iseq` makes per file.

| Measurement | main | branch | ratio |
| --- | --- | --- | --- |
| Rewrite of 178 real files (26 gem lib + 152 fixtures), wall | 126 ms | 543 ms | 4.3x |
| Rewrite of the same 178 files, allocated objects | 94k | 837k | 8.9x |
| Rewrite of `lib/branchproof/instrumenter.rb` alone | 0.86 ms | 9.93 ms | 11.5x |
| `Source#inventory` + rewrite, gem's 37 lib files, best of 5 | 0.288 s | 0.828 s | 2.9x |
| Decisions found in the gem's 37 lib files | 1,795 | 4,005 | 2.2x |
| Synthetic construct file, 200k calls, per call | 187 µs | 495 µs | 2.6x |
| `while` loop over `arr[i]`, slowdown vs uninstrumented | 266x | 587x | 2.2x |
| Allocated objects per `arr[i]` evaluation | 34 | 74 | 2.2x |
| `Evidence#record` calls per `arr[i]` evaluation | 0 | 1 | — |

Decision breakdown on the branch for the gem's own lib (4,005 total): lookup 1,409; if 573; iteration 481; unless 475; short_circuit 336; ternary 225; predicate 212; default_argument 81; safe_navigation 47; or_assignment 39; rescue 35; case 30; elsif 27; bitwise 15; dispatch 9; while 4; until 3; and_assignment 3; comparison 1. Every pre-existing boolean context has an identical count on main. All growth is the new families, and `[]` lookups alone are 35% of all decisions.

Per-hit cost on the runtime path is unchanged from main and is the reason growth hurts: each recorded decision allocates a frame hash and observation arrays in `runtime.rb`, then `Evidence#record` does a deep `symbolize` copy, `JSON.generate`, and a SHA256 digest.

## Prioritized actions

P1 is required before merge. P2 is required before recommending the branch for real projects. P3 is cleanup or a documented decision.

| ID | Priority | Action | Dependency |
| --- | --- | --- | --- |
| RC-01 | P1 | Stop crashing on `it`, `_1`, and empty-parens defaults; degrade every rewrite failure to a diagnostic | None |
| RC-02 | P1 | Guard exception wrappers against void-value bodies | None |
| RC-03 | P1 | Record the outer iteration frame correctly when the block is yielded from another frame | None |
| RC-04 | P1 | Remove the unreachable "false" alternative for bitwise operators | None |
| RC-05 | P2 | Decide and bound the runtime scope of value decisions | RC-04 |
| RC-06 | P2 | Restore one parse and one compile per file for default parameters | RC-01 |
| RC-07 | P2 | Fold value discovery into the single AST walk | None |
| RC-08 | P2 | Remove per-iteration and per-hit allocations in the new runtime helpers | RC-03 |
| RC-09 | P2 | Bound the enclosure precompute for large decision counts | RC-05, RC-07 |
| RC-10 | P3 | Restore the exact assertions in the decision-expansion acceptance test | None |
| RC-11 | P3 | Document the new contexts and update signatures | RC-04, RC-05 |

### RC-01 — Stop crashing on implicit block parameters and unusual defaults

- [x] Complete and verify.

**Evidence:** [default_instrumentation.rb:50-75](../../lib/branchproof/default_instrumentation.rb) walks every `DefNode`, `LambdaNode`, and `BlockNode` in the file once any default decision is supported, then calls `parameters.optionals` and `parameters.keywords`. Blocks using `it` or `_1` give `Prism::ItParametersNode` or `Prism::NumberedParametersNode`, which do not respond to those methods. `Instrumenter#rewrite` rescues only `SyntaxError` ([default_instrumentation.rb:26](../../lib/branchproof/default_instrumentation.rb), [instrumenter.rb](../../lib/branchproof/instrumenter.rb)), and `Loader#load_iseq` rescues only `Errno::ENOENT` ([loader.rb:68](../../lib/branchproof/loader.rb)), so the user's `require` raises.

```ruby
def with_default(a, b = 1) = a + b
def uses_it(items) = items.select { it > 0 }
# NoMethodError: undefined method 'optionals' for an instance of Prism::ItParametersNode
```

The gem's own `analyzer.rb` and `minimizer.rb` trigger this. A second shape in the same method crashes on `value.body.body` for an empty-parens default, for example `->(y = ()) { y }` placed inside a `defined?` operand so pass one never wraps it: `NoMethodError: undefined method 'body' for nil`.

**Action:** in `default_bindings`, return `[]` unless `parameters.is_a?(Prism::ParametersNode)` after unwrapping `BlockParametersNode`. Guard every dereference of `value.body`, `value.statements`, and `first` with nil checks. Wrap the whole second pass so any `StandardError` becomes an `invalid_default_rewrite` diagnostic on the result with `changed: false`, and keep the first-pass bytes untouched in that case. In `Loader#load_iseq`, rescue `StandardError` around `@instrumenter.rewrite`, add a `rewrite_failure` diagnostic with the exception class and message, and return `nil` so Ruby loads the original file. A rewrite failure must never propagate out of the load hook.

**Acceptance:** regressions for `it`, `_1`, and `()` defaults in a file that also has a supported default parameter: rewrite returns without raising, the diagnostics name the reason, and the loader loads the file. Instrumenting `lib/branchproof/*.rb` with the gem's own instrumenter raises nothing. A test that stubs `rewrite` to raise confirms the loader records a diagnostic and still returns `nil`.

### RC-02 — Guard exception wrappers against void-value bodies

- [x] Complete and verify.

**Evidence:** [exception_instrumentation.rb:33-36](../../lib/branchproof/exception_instrumentation.rb) wraps the protected body as `exception_value(id, (begin; body; end), 0)`. When the body's last statement is a bare `return`, `break`, `next`, or `redo`, Ruby rejects the argument with `unexpected void value expression`. `Instrumenter#rewrite` catches the `SyntaxError`, returns `changed: false` with a warning-severity `invalid_rewrite` diagnostic, and the loader loads the original file. Every decision in that file is lost, not only the rescue. The branch already added `nonlocal_transfer?` at [instrumenter.rb:158](../../lib/branchproof/instrumenter.rb) for boolean conditions; the same guard is missing here.

```ruby
def bar
  begin
    puts "trying"
    return 6
  rescue => e
    puts "rescued"
  end
  "after"
end
```

```ruby
def g(items)
  items.each do |i|
    begin
      work(i)
      next
    rescue StandardError
      log
    end
  end
end
```

Both produce `changed: false, iseq: nil` and an `invalid_rewrite` warning. Modifier forms such as `return 5 if flag` are fine. The rescue-modifier wrapper at [exception_instrumentation.rb:64](../../lib/branchproof/exception_instrumentation.rb) uses the same shape and should be checked with `x rescue return nil` and `x rescue next`.

**Action:** when the last statement of `normal_body` is a non-local transfer, do not wrap the body as a value. Insert `exception_path(id, 0)` as a statement before that final transfer instead, the same way the `normal_insert_at` path already inserts a statement. Detect the transfer on the Prism node during inventory (last statement is `ReturnNode`, `BreakNode`, `NextNode`, or `RedoNode`) and store the insertion offset in the decision metadata, rather than pattern matching rendered text. Apply the same rule to the rescue-modifier right-hand side and to the `required_pattern` and `value` wrappers if their expression can be a transfer.

**Acceptance:** the two snippets above rewrite with `changed: true`, no diagnostics, a compiled `iseq`, and native-versus-instrumented differential checks match return values and side effects. Path 0 is recorded for the normal completion, path 1 for the rescued path. Add a corpus fixture family for transfer-terminated protected bodies so `test_ruby_construct_behavior.rb` and `test_ruby_construct_examples.rb` cover it.

### RC-03 — Record the outer iteration frame when the block is yielded from another frame

- [x] Complete and verify.

**Evidence:** [iteration_runtime.rb:52-56](../../lib/branchproof/iteration_runtime.rb) `iteration_frame` only inspects the top of the frame stack. With a user-defined `each` that yields, the block runs while the inner `@items.each` frame is on top. `flow_iteration_callback` misses the outer frame, opens a throwaway frame per yield, and records "entered" once per element. The original outer frame is never marked finished, so `flow_iteration_finish` records path 0, "empty", after the loop. No diagnostic is raised because this helper deliberately does not latch.

```ruby
class Bag
  include Enumerable
  def initialize(items) = @items = items
  def each
    @items.each { |item| yield item }
  end
end
def run(bag)
  seen = []
  bag.each { |x| seen << x }
  seen
end
```

Calling `run(Bag.new([1, 2, 3]))` records four executions for the outer `bag.each`: three "entered" and one "empty". The report shows the "empty" alternative as covered although the bag was never empty. `Bag.new([])` records correctly.

**Action:** find the frame for `decision_id` by searching the stack from the top instead of checking only the last entry, and mark that frame finished from the callback. Keep the throwaway-frame path only for callbacks with no matching frame anywhere on the stack (deferred and lazy callbacks). Decide explicitly whether a callback that runs while a different decision is on top should latch a diagnostic; it must not silently produce evidence for the wrong alternative.

**Acceptance:** the snippet above records exactly one execution for the outer decision with the "entered" alternative and none for "empty". The nested case `outer.each { inner.each { } }`, a block invoked from `define_method`, a stored `Proc` invoked later, and a lazy chain all keep their current recorded results. Add this shape to the corpus.

### RC-04 — Remove the unreachable "false" alternative for bitwise operators

- [x] Complete and verify.

**Evidence:** [value_syntax.rb:10,61](../../lib/branchproof/value_syntax.rb) classifies `&`, `|`, and `^` as truthiness decisions with alternatives `false` and `true`. `Integer#&`, `Integer#|`, and `Integer#^` always return an Integer, and `0` is truthy, so the `false` alternative can never be observed. The conditions view for `def mask(x) = x & 1` shows alternative 0 as `unexecuted` after calling `mask(2)` and `mask(3)`, and alternative coverage is capped at 1/2 for every such decision. A 100% gate can never pass.

**Action:** drop `BITWISE_OPERATORS` from value decisions. If boolean `&`/`|`/`^` on `true`/`false` receivers is worth keeping, it needs a receiver-type signal at runtime that only records when the result is `true` or `false`, and the alternative must be reported as "not applicable" otherwise. The simpler and safer choice is removal.

**Acceptance:** `x & 1`, `a | b`, and `a ^ b` produce no decision. `x == y` still records both alternatives. Update `expectations/source.json` deliberately for the removed contexts.

**Resolution — 2026-09-18:** Reproduced on Ruby 3.4.7: `x & 1` produced a supported two-alternative decision, while integer results remained truthy and could only select the `true` alternative. Removed `&`, `|`, and `^` from value discovery. Boolean comparisons and predicate calls remain covered; Boolean bitwise support is deferred because it requires a receiver-type applicability contract.

### RC-05 — Decide and bound the runtime scope of value decisions

- [x] Complete and verify.

**Evidence:** every `[]` call, every `?`-suffixed call, every `<=>`, `send`, and comparison operator not already a control-flow condition becomes a decision that runs the full `enter`, `value_path`, `leave`, and `Evidence#record` cycle per evaluation. On the gem's own lib this is 1,409 lookup decisions plus 212 predicates out of 4,005. In a `while` loop over `arr[i]` the branch is 587x slower than uninstrumented versus 266x on main, at 74 allocated objects and one `record` call, including `JSON.generate` and SHA256, per element.

**Action:** make a written decision with three options and pick one. Option A: value decisions are opt-in through a limit or configuration flag, default off. Option B: keep them on, but exclude `[]` by default since it is the largest and least informative family. Option C: keep the scope but memoize per decision in the runtime: keep a small per-decision set of already-recorded `(observations, outcome, test_id, phase)` keys and skip `safely_record` for repeats, so the JSON and digest work happens once per distinct vector per test rather than once per evaluation. Option C changes no evidence content because `Evidence#record` already deduplicates by vector id, only the counts differ, so the `count` field needs a decision. Options A or B can be combined with C.

**Acceptance:** re-run the `arr[i]` micro-benchmark and the 200k-call synthetic benchmark. Record the new ratios in this document. The chosen option is documented in the README with its default. Attribution to tests and phases is unchanged in the saved report for the corpus.

**Assessment — 2026-09-18:** Option A is the safest product default but would make the newly measurable value families surprising and requires a configuration/schema decision. Option B bounds the largest family but silently removes useful false/nil lookup evidence. Recommend Option C for the current release, with per-decision memoization keyed by observations, outcome, test ID, and phase; it preserves decision IDs, test/phase attribution, vector content, and report coverage while avoiding repeated JSON/digest work. Keep the scope decision explicit in the README, and revisit an opt-in/default-off mode after corpus measurements. Do not exclude lookup until a user-facing scope decision is approved.

### RC-06 — Restore one parse and one compile per file for default parameters

- [x] Complete and verify.

**Evidence:** [default_instrumentation.rb:12-28](../../lib/branchproof/default_instrumentation.rb) calls `super`, which already applies edits and compiles once, then re-parses the rewritten bytes with `Prism.parse` at line 21, walks the whole tree again in `default_body_edits`, applies a second edit list, and compiles again at line 23. A `TracePoint` around one `rewrite` on a file with a default parameter counts one extra `Prism.parse` and two `RubyVM::InstructionSequence.compile` calls. This undoes the "walk each file's AST once" and "reuse the instrumenter's validation compile" invariants from commits `4bfe135` and `f52f72c`. `default_flag` at line 44 scans the full file with `String#include?` and is called twice per decision, once in `render_flow` and once in `rewrite`.

**Action:** collect the body-entry offsets during the existing single walk in [source.rb:122](../../lib/branchproof/source.rb) `collect_ast_nodes`. For each def, lambda, or block that owns a default parameter, store the original-offset insertion point (first body statement, or the `rescue`/`ensure` keyword, or the closing token, and the `equal_loc` case for endless defs) in the decision's instrumentation metadata. Emit the entry marker as a zero-length insert edit at the original offset in the same edit list as the default-value replacement, so `apply_edits` and the compile run once. Compute the flag name once and pass it through. Remove the second parse and second compile entirely.

**Acceptance:** a `TracePoint` test asserts exactly one `Prism.parse` in `Source` and one `InstructionSequence.compile` in `Instrumenter#rewrite` for a file with defaults. All default-coverage tests and the `arg_*` corpus fixtures pass unchanged. Rewrite time for `lib/branchproof/instrumenter.rb` is re-measured and recorded.

### RC-07 — Fold value discovery into the single AST walk

- [x] Complete and verify.

**Evidence:** [value_syntax.rb:13-31](../../lib/branchproof/value_syntax.rb) runs `super` for the fused walk, then performs a complete second traversal of `program` through `walk_skipping_defined_operands` for every file, whether or not the file contains any candidate node. `IterationSyntax`, `ExceptionSyntax`, and `DefaultSyntax` all hook into the existing walk through `flow_decision_node?` and `flow_details`. The `occupied` hash is keyed by freshly allocated two-element arrays per node.

**Action:** classify value nodes inside the same walk that produces the other decisions. The occupied-range check can be done after the walk on the collected list, or at collection time by marking condition ranges as the fused walk creates them. Avoid allocating a range array per visited node; compare `start_offset` and `length` directly or key by a packed integer.

**Acceptance:** `Source#inventory` on the gem's 37 lib files produces the same decision list (ids, contexts, offsets) as before, verified by diffing the two inventories. A test asserts the walker visits each node once. Inventory time for the 180-file corpus is re-measured and recorded.

### RC-08 — Remove per-iteration and per-hit allocations in the new runtime helpers

- [x] Complete and verify.

**Evidence:**

- [iteration_runtime.rb:17-19](../../lib/branchproof/iteration_runtime.rb) calls `flow_path` on every block element although the frame is finished after the first. Measured at 4 allocated objects per iteration on a 10,000-element `each`, with only one `record` call.
- [value_instrumentation.rb:20,30](../../lib/branchproof/value_instrumentation.rb) emits the domain as a quoted string literal. In files without the frozen string pragma this allocates a String per hit, then [value_runtime.rb:41-45](../../lib/branchproof/value_runtime.rb) does a string-keyed `Hash#fetch` and a lambda call.
- [exception_runtime.rb:37-41](../../lib/branchproof/exception_runtime.rb) uses an explicit `Branchproof::Runtime.leave` with a comment saying a bare call would not resolve. A bare `leave` resolves correctly, as `runtime_flow.rb` already relies on for `current_frame`.

**Action:** in `flow_iteration_callback`, return early when the matched frame is already finished. Emit the domain as a Symbol and dispatch in `value_path` with a `case` on the symbol. Replace the explicit receiver in `exception_leave` with a bare call and fix the comment. Consider an early `return` in the new entry points when `@storage_disabled` is set, so a forked or latched process does not keep paying for probes it will discard.

**Acceptance:** `GC.stat(:total_allocated_objects)` delta across a 10,000-element `each` is constant, not proportional to element count, for the iteration decision itself. `value_path` allocates nothing beyond the frame bookkeeping. Existing runtime tests pass.

**Value portion — 2026-09-18:** Completed the value-runtime portion: generated instrumentation now passes a Symbol domain, `value_path` dispatches directly by `case` instead of string-keyed lambda lookup, and finished frames return before duplicate path work. Iteration callbacks now return immediately for completed matching frames; exception cleanup uses the existing bare `leave` helper.

### RC-09 — Bound the enclosure precompute for large decision counts

- [x] Complete and verify.

**Evidence:** [instrumenter.rb:62](../../lib/branchproof/instrumenter.rb) `build_enclosures` compares every decision with every other decision. It is unchanged on this branch, but the decision count per file grew 2.2x, so comparisons grew roughly 5x. This is the main reason `instrumenter.rb` rewrites 11.5x slower.

**Action:** sort decisions by `byte_start` once and compute containment with a single sweep and a stack, or an interval tree if nesting is deep. The result must be identical to the current map. Do this after RC-05 and RC-07 so the measurement reflects the final decision count.

**Acceptance:** a test compares the sweep result with the quadratic result on the corpus. Rewrite time for the 178-file corpus is re-measured and recorded; the target is within 1.5x of main for the same files with value decisions in their final scope.

### RC-10 — Restore the exact assertions in the decision-expansion acceptance test

- [x] Complete and verify.

**Evidence:** [test_decision_expansion_acceptance.rb:49-54](../../test/test_decision_expansion_acceptance.rb) replaced `assert_equal` on the sorted context list, `supported_decisions == 3`, and `required_alternatives == 7` with `assert_includes` per context and `>=` bounds. The fixture is unchanged and still produces exactly six decisions, exactly those six contexts, three supported decisions, and seven required alternatives, so the relaxation was not needed. It hides future count drift.

**Action:** restore the exact assertions. If the value-decision scope from RC-05 adds decisions to that fixture, assert the new exact values rather than a lower bound.

**Acceptance:** the test asserts exact values and passes.

### RC-11 — Document the new contexts and update signatures

- [x] Complete and verify.

**Evidence:** the README "Supported decision forms" tables list `comparison`, `lookup`, and `predicate` but not `dispatch`, `bitwise`, `match_capture`, or `lazy_callback`, all of which appear in saved reports. `sig/branchproof.rbs` has no entries for the thirteen new modules, consistent with the existing omission of internal mixins. The synthetic `__branchproof_default_*` locals are visible in `local_variables` and debuggers; the plan records this but the README does not.

**Action:** add a table row per context that survives RC-04 and RC-05, with its required alternatives. State the `local_variables` side effect in the README limitations. Add RBS entries for the new runtime methods that generated code calls, since they are a public surface for instrumented files. Keep `doc/` and `llms.txt` regeneration to the release step.

**Acceptance:** every `context` value emitted by `value_syntax.rb` and `iteration_syntax.rb` has a README row. `bundle exec rake docs` regenerates without errors.

## Execution order and verification

1. RC-01 through RC-04 first, each with a failing regression before the fix, in separate commits. RC-01 and RC-02 are load-path safety; RC-03 and RC-04 are evidence correctness.
2. Make the RC-05 scope decision before the performance work, since it changes the decision counts that RC-06, RC-07, and RC-09 are measured against.
3. RC-06 and RC-07 restore the single-pass invariants. Verify each with a `TracePoint` count test, not only timing.
4. RC-08 and RC-09 are measured changes. Record before-and-after numbers in this document.
5. RC-10 and RC-11 last.

Rules for the implementer: do not add dependencies. Benchmark and utility scripts use the Ruby standard library only. Do not rerun the application test suite per fix while iterating on runtime helpers; use the focused suites, then run the full `bundle exec rake` once per action. Re-run the Rails integration job with `BRANCHPROOF_RAILS_INTEGRATION=1` before claiming Rails verification. Update `expectations/source.json` deliberately and explain every changed entry in the commit message.

Verification evidence from this review, on the unchanged reviewed commit:

- Full suite: 1,422 runs, 219,820 assertions, zero failures or errors, five Rails skips. RuboCop: 124 files, zero offenses.
- Native-versus-instrumented differential checks passed for dependent defaults, defaults referencing `self` and instance variables, `return` inside a default, block-parameter defaults, lambda defaults, keyword defaults with `**rest`, endless defs, `retry`, raising `ensure`, `rescue *ERRORS`, `break` inside an instrumented block, safe-navigation `||=` with a nil receiver, multibyte text before an instrumented construct, and eight threads through a recursive default plus rescue. `method(:f).parameters` is unchanged by instrumentation.
- Reproductions confirmed RC-01 (two shapes), RC-02 (two shapes), RC-03, and RC-04 by execution.
- The double parse and double compile in RC-06 were counted with `TracePoint`.
- The measurements table above is the performance baseline for this branch.

Completion requires passing checks, explicit resolution of RC-01 through RC-04, a recorded decision for RC-05 with re-measured numbers, and updated measurements after RC-06 through RC-09. A green suite alone does not establish either evidence correctness or load-path performance, because the current suite passes with all four defects present.

## Verified resolutions — 2026-09-18

Luna subagents independently reproduced the findings and implemented bounded fixes. Integration checks additionally caught and fixed lost exception probes in iterator blocks with implicit rescue bodies. No dependencies were added. Version remains 0.9.0.

| Action | Implemented resolution and evidence |
| --- | --- |
| RC-01 | Implicit `it`/`_1` parameter nodes and empty defaults no longer crash rewriting. The loader catches rewrite failures, records their class/message, and falls back to Ruby loading. RC-06 subsequently removed the second pass entirely, so its temporary `invalid_default_rewrite` fallback is no longer needed. Every supported decision in the gem's library has a generated probe; all library rewrites compile without diagnostics. |
| RC-02 | Protected-body transfers remain statements. Return/break/next arguments evaluate before the normal-path marker, preserving rescue behavior when an argument raises; multiargument and splatted transfers preserve their values. Empty bodies remain nil. EXC-15 adds native return, break, next, and bounded redo cases. |
| RC-03 | Callbacks search for the matching active frame and mark it directly, rather than recording on whichever frame is on top. A nonempty custom iterator records exactly one entered observation and no empty observation. LOOP-10 covers nested yielding; focused tests also cover nested iterators, stored/deferred callbacks, and define_method. |
| RC-04 | `&`, `|`, and `^` create no value decisions. PRED-15 remains a native-behavior fixture with an intentionally empty decision inventory. Comparisons still record both alternatives. The source snapshot deliberately removes three bitwise decisions. |
| RC-05 | Choose Option C: retain enabled value coverage and cache one most recent successful completed trace per decision inside Evidence. Keys include run, observations, outcome, test, and phase. Cache hits still increment all execution/phase counts; invalid, aborted, and limited traces use the normal path. Option A would hide newly supported families by default; Option B would discard useful false/nil lookup evidence. Neither was selected. Mutable input keys are copied, merges invalidate cache entries, and mixed cached/uncached sequences produce identical saved evidence. |
| RC-06 | Original AST owner offsets drive default markers in the existing edit tree. No second parse, walk, splice pass, or compile remains. A scoped TracePoint test asserts one Prism parse and one validation compile. Defaults compose with implicit rescue and iterator bodies without dropping nested probes. |
| RC-07 | The existing collection walk also gathers value candidates; occupied ranges use packed integer keys. A walker-count test verifies each visited node occurs once in that collection walk; existing local unsupported-reason scans remain. Fixed-input inventory comparison preserves all 4,270 non-bitwise IDs, source IDs, contexts, offsets, expressions, and condition ranges. Equal-offset tie ordering can differ. The only removed inventory entries are 18 bitwise decisions. |
| RC-08 | Finished iteration frames return before further work; 10,000 repeated callbacks allocate no additional objects. Generated value domains are symbols with direct case dispatch, replacing per-hit strings and lambda lookup. Exception cleanup reuses bare `leave`. Entry-point storage-disabled shortcuts were not added because frame cleanup semantics must remain intact. |
| RC-09 | Enclosure discovery sweeps active intervals instead of comparing every disjoint pair. Tests compare the result with the previous quadratic algorithm across the corpus and crossing/equal ranges, and bound comparisons for 1,000 disjoint decisions. Deeply nested inputs can still require quadratic output when every pair is genuinely related. The measured corpus rewrite is below the 1.5x-main target. |
| RC-10 | Restored exact six contexts, three supported Boolean decisions, and seven required alternatives in the unchanged acceptance fixture. |
| RC-11 | README documents dispatch, match capture, lazy callbacks, bitwise exclusion, and the cache/default scope. The synthetic default-local limitation was already documented and remains. RBS includes generated runtime calls. `bundle exec rake docs` succeeds; generated `doc/` and `llms.txt` changes remain reserved for release. |

The corpus now contains **144 fixtures, 406 native cases, 285 decisions, and 143 decision-bearing fixtures**. Snapshot changes are deliberate: remove PRED-15's three decisions, add LOOP-10's two decisions, and add EXC-15's nine decisions (277 - 3 + 2 + 9 = 285).

### Final performance measurements

Ruby 3.4.7, Prism 1.x, sequential processes, medians of three samples. All versions read the same fixed 193-file cohort from the reviewed commit: 41 library files plus 152 fixture files. This cohort differs from the original 178-file table above. Rewrite timing excludes source inventory. Instrumenter-only samples average 100 rewrites. Runtime benchmarks use 200,000 measured observations/calls after warmup.

| Measurement | main (`d7cfba2`) | reviewed (`bd8c97e`) | fixed |
| --- | ---: | ---: | ---: |
| Rewrite, 193 files | 141.0 ms | 648.6 ms | 120.7 ms |
| Rewrite allocations | 111,581 | 926,249 | 234,856 |
| Rewrite errors in this cohort | 1 | 4 | 0 |
| `instrumenter.rb` rewrite | 0.873 ms | 8.199 ms | 1.897 ms |
| `instrumenter.rb` rewrite allocations | 1,422 | 28,391 | 4,073 |
| Lookup loop wall time | 1.664 s | 3.585 s | 1.629 s |
| Lookup loop slowdown versus native | 237x | 514x | 236x |
| Lookup loop allocations | 6,868,000 | 14,868,000 | 7,144,000 |
| Synthetic 200k calls wall time | 2.062 s | 8.060 s | 3.282 s |
| Synthetic slowdown versus native | 56x | 228x | 92x |
| Synthetic allocated objects | 9,000,000 | 32,600,000 | 14,400,000 |

Main measures fewer decisions (1,973 versus 4,270 across the cohort; one versus four in the synthetic example). Its pre-existing `flow_06.rb` rewrite error and the reviewed commit's analyzer/minimizer crashes and CLI/source invalid rewrites are included in timings, not silently omitted. Fixed rewrite is 81% faster than reviewed and 0.86x main overall; the instrumenter-only file remains 2.17x main while measuring 77 decisions versus 22. Lookup and synthetic runtime improve by 55% and 59% respectively versus reviewed.

Lookup benchmark: 2,000 calls over a 100-element array using `while i < arr.length; arr[i]; i += 1; end`. Synthetic benchmark: 200,000 calls to the following method with `value = 1`:

```ruby
def example(value, fallback = false)
  found = [value][0]
  positive = value.positive?
  chosen = positive && found
  [chosen, fallback]
end
```

The cache is intentionally bounded to one recent trace per decision. Consecutive equivalent traces benefit; alternating observations, tests, or phases still validate and serialize normally. These tight-loop timings do not predict whole-application overhead.

Source inventory alone on that same 193-file input (median of five sequential samples) measured **315.8 ms / 988,165 allocations before** and **318.5 ms / 925,485 allocations after**. Allocation volume fell 6.3%; wall time was essentially unchanged (+0.9%). The fused collection walk is verified structurally, without claiming a measured inventory speedup.

### Final verification

- CRuby 3.3.6: **1,466 tests, 225,398 assertions, zero failures/errors**, five optional Rails skips.
- CRuby 3.4.7: **1,466 tests, 225,398 assertions, zero failures/errors**, five optional Rails skips.
- Rails integration explicitly enabled: **5 tests, 142 assertions, zero failures/errors/skips**.
- RuboCop: **130 files, zero offenses**. The rake lint phase could not write the sandbox-external cache; rerunning `bundle exec rubocop --no-server --cache false` passed.
- `bundle exec rake docs`: passed; generated release artifacts were restored.
- RBS parsing: passed with installed Ruby 3.3 / RBS 3.6.1. Installed Ruby 3.4 / RBS 4.2 crashes even on minimal signature input, so it was not used as verification evidence.
- Fixed-input inventories: all **4,270 non-bitwise decision records** match by ID, source, context, location, expression, and condition ranges; no unexpected additions or removals.
- Luna's final read-only review of the default/iteration/rescue composition, fused discovery, and enclosure changes found no concrete blockers.
- `git diff --check`: passed.

Remaining limits: bitwise expressions are intentionally outside measurable decision coverage; alternating traces retain normal recording costs; deeply nested enclosure output can still be quadratic; runtime tests covered CRuby 3.3 and 3.4, not other Ruby engines or versions.
