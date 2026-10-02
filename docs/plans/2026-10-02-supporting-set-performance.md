# Faster level-3 supporting sets

Approved workspace plan: `.omx/plans/2026-10-02-next-implementation.md`.
Base: `85611af`. Runtime: CRuby 4.0.1. No new dependencies.

## Cleanup plan and invariants

The initial hypothesis was repeated construction of minimizer inputs. First
repair benchmark compatibility, then lock full result behavior, then remove
work in the measured hotspot. Keep the search algorithm unchanged.

Fresh Ruby 4 diagnostic evidence (one exploratory 2,000-example/100-decision
ordinary RSpec run): minimization took 5.718 seconds, its global test-cover call
5.665 seconds, and greedy calls 5.657 seconds. Obligation/vector/test candidate
construction took milliseconds. Therefore this slice targets greedy's repeated
set-difference/union work rather than introducing input indexes or constructor
caches. This also preserves the existing behavior for callers that mutate input
hashes between calls. Repeated baseline/candidate samples remain required.

Scope: `benchmark/pipeline.rb`, benchmark support/comparator tests,
`lib/branchproof/minimizer.rb`, its regression tests, and performance records.
Supporting-set rendering is a separate optimization unless fresh measurements
show it dominates. Duplicate CLI snapshots, persistent caches, changed-code
selection, and mutation are outside this slice.

Preserve scope and candidate order, selected/necessary/interchangeable/additional
IDs, exact/BEST_FOUND/NOT_AVAILABLE labels, lower bounds, visited-node counts,
budget accounting, test/phase attribution, witness pairs, diagnostics,
completeness, report schemas and exit status. Index construction cost belongs in
the benchmark. Do not weaken coverage or omit tests for speed.

## Delivery checklist

- [x] Verify clean baseline tests and RuboCop (1,694 tests, zero failures/errors;
      185 files, zero offenses; redirect RuboCop cache to a writable temp path).
- [x] Make the pipeline run on Ruby 4 without Fiddle or new dependencies;
      preserve allocations and wall time, report memory limitations honestly.
- [x] Add complete-report semantic comparison, normalizing only enumerated
      nondeterministic metadata; prove semantic mutations are rejected.
- [ ] Capture baseline samples: small and 2,000-test/100-decision workloads,
      ordinary/shared RSpec and Minitest, levels 1 and 3, repeated serial runs.
- [ ] Add full-result regressions before changing production code.
- [ ] Remove repeated set construction in the measured greedy hotspot; retain
      the search algorithm and complete result behavior.
- [ ] Compare baseline/candidate documents and repeated measurements.
- [ ] Run full tests/RuboCop, RBS validation, whitespace checks and independent
      behavior/code reviews, then publish a new PR.

## Acceptance

At least 10% less targeted phase time or allocations, with no repeatable
regression over 5% on unaffected end-to-end wall time or measured peak RSS.
Differences within noise require more samples. If a candidate misses the gate,
drop it and retain the measurement finding. Missing RSS data cannot prove a
memory-regression claim.

Complete semantic parity is mandatory. Equivalence tests must reject changes to
counts, IDs, owner/phase data, witness/minimum labels, diagnostics, completeness
and exit status. Failed/incomplete/unattributed and exact-budget cases remain
covered by focused and subprocess tests.

## Verification commands

Use the Ruby 4.0.1 executable directory first in PATH for every command.

```sh
bundle exec rake
bundle exec ruby -Ilib:test test/test_minimizer.rb
bundle exec ruby -Ilib:test test/test_benchmark_contract.rb
REPEATS=3 FRAMEWORKS=rspec,minitest SUITES=ordinary,shared LEVELS=1,3 bundle exec ruby benchmark/pipeline.rb
git diff --check
```

RBS validation uses the installed RBS CLI outside the application's bundle when
RBS is not a declared development dependency. Record optional Rails evidence
separately; core tests do not establish external Rails performance parity.
