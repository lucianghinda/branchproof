# Measurable Ruby constructs for 0.9.0

The second commit on PR #7 extends the existing corpus from discovery and
exclusion tests to executable coverage. Preserve native return values, evaluation
order, exceptions, local bindings, and side effects throughout.

## Coverage contracts

- Contextual predicates: observe flip-flop and implicit regexp outcomes in Ruby's
  conditional context. Observe `defined?` without evaluating its operand.
- Matching: guarded pattern clauses include guard acceptance in clause selection;
  dynamic `when` splats form one static candidate group. Rightward assignment
  measures successful matching and mismatch, retaining the native exception.
- Assignment: safe navigation compound assignment distinguishes nil receivers,
  skipped right-hand sides, and evaluated right-hand sides.
- Exceptions: observe native rescue selection and normal completion; preserve
  `retry`, `ensure`, exception identity, and unwinding.
- Parameter binding: measure supplied versus defaulted optional parameters
  independently, including dependent defaults and lambdas.
- Returned predicates: measure standalone predicate outcomes; value-returning
  comparisons, lookup, and dispatch use named alternatives where Boolean
  interpretation would misrepresent their semantics.
- Iteration and callbacks: measure actual body entry and predicate evaluation;
  fetch fallback is absence-based. Lazy callbacks count only when demanded.

Boolean coverage retains existing criterion semantics. Alternative observations
participate in alternative coverage, not fabricated MC/DC over library internals.
The Ruby construct corpus must contain no silently ignored fixture families.

## Implementation and verification

Use bounded Luna implementation lanes for contextual predicates, alternatives,
exceptions, defaults, and value observations. Integrate their modules with the
existing source/instrumentation/runtime architecture. Add focused regressions
before production changes, then review native behavior and exact evidence.

Update the reviewed source expectations and affected assertions deliberately.
Verify all 400 native cases after rewriting, all supported report levels and
criteria, saved reports, CLI integration, and supported Ruby versions. Run the
full suite and lint, then review the diff. Update the gem version and changelog
to 0.9.0 and push one additional Lore-format commit to the existing PR.

## Implementation record

The reviewed inventory now contains 277 supported decisions across all 142
fixtures: 116 Boolean, 114 implicit, 15 pattern, 14 multiway, and 18 exception
decisions. No fixture is empty and none of the corpus decisions is excluded.
Snapshot version 2 also records exact alternative expressions and byte ranges.

Luna implementation and review lanes covered matching, contextual predicates,
exception paths, defaults, returned values, iteration, and compatibility tests.
Integration regressions found and corrected invalid binary dispatch traces,
lazy callbacks corrupting unrelated frames, exception-constant shadowing, and
default rewrites that changed local scope or leaked pending state after errors.
Defaults now use invocation-local flags and a second parse for body locations.

The boundaries remain explicit: a splat is one static candidate group, eager
operators and returned predicates use alternative coverage, lazy callbacks count
only when demanded, and arbitrary library internals are not instrumented. Default
flags are visible to local-variable introspection. Existing unsupported heredoc,
data-section, and subjectless-case-splat tests remain negative controls.

## Verification

- CRuby 3.3.6 and 3.4.7: 1,422 tests, 219,825 assertions, zero failures or
  errors. Each core run skips the five optional Rails tests.
- Rails integration on Ruby 3.4.7: five tests, 142 assertions, zero failures,
  errors, or skips.
- Focused new-feature suites: 29 tests, 482 assertions, zero failures/errors.
- The final tightened guard-vector anchor passes independently: one test,
  16 assertions. Guard vectors are checked exactly, independently of the newly
  supported outer pattern alternatives.
- RuboCop: 124 files, no offenses. Staged whitespace validation is clean.

## Current corpus review follow-up — 2026-09-18

The catalog has since expanded to 144 fixtures and 406 native cases. Current
source expectations contain 285 decisions across 143 decision-bearing
fixtures. `PRED-15` remains an intentional no-decision fixture because eager
integer bitwise results do not provide a meaningful false/truthy domain; those
operators are explicitly excluded from coverage. The 277-decision, 142-fixture
inventory above is retained as the historical implementation record for the
earlier corpus state.
