# Level-3 supporting-set performance — 2026-10-02

Counting uncovered obligations directly in greedy selection reduced large
level-3 minimization time by 91.6–91.9% and normal CLI wall time by 70.1–76.8%.
The search, tie order, budgets and complete result behavior are unchanged.

## Method

Both variants used CRuby 4.0.1 + Prism on arm64-darwin25, Minitest 5.27.0,
Prism 1.9.0 and RSpec Core 3.13.6, without new dependencies. Baseline commit
`f370702` contains the benchmark repairs and original production minimizer.
The [sample data](data/supporting-set-performance-2026-10-02.json) records both
production source SHA256 digests and all 144 measured executions.

Small workloads contain two tests, one decision and two observed vectors.
Large workloads contain 2,000 tests, 100 decisions and 200 observed vectors.
Each decision is `admin && active`; tests hold `admin` true and alternate
`active`. These deliberately redundant supporting-test candidates stress the
global greedy cover. They do not establish performance for every project or
for external Rails boot.

Each workload/framework/suite/level/variant combination ran three times,
serially. Baseline/candidate order alternated by repetition. Both used the same
fixture directory and seed 1234; RSpec reports randomized order with that seed.
No tests or reviews ran concurrently with measurements.

The pipeline wrapper measures disjoint inventory, worker, analysis, minimizer
initialization, minimization and rendering phases. Scope/detail breakdowns are
nested and must not be added to the phase total. Initialization includes any
construction cost. Separate normal CLI runs have no allocation probe or phase
wrapper; their wall time includes launching Bundler. Consequently compare
variants within each mode, rather than comparing absolute times between modes.

## Results

Large workload medians, seconds (three samples each):

| Framework / suite | Level-3 minimization, baseline → candidate | Reduction | Normal CLI level-3 wall, baseline → candidate | Reduction |
| --- | ---: | ---: | ---: | ---: |
| RSpec / ordinary | 5.7725 → 0.4754 | 91.8% | 7.2979 → 1.9880 | 72.8% |
| RSpec / shared examples | 5.7911 → 0.4858 | 91.6% | 7.6333 → 2.2811 | 70.1% |
| Minitest / ordinary | 5.7839 → 0.4702 | 91.9% | 6.9305 → 1.6097 | 76.8% |

Normal CLI wall medians for unaffected cases; a positive change is slower:

| Workload | Framework / suite | Level | Baseline | Candidate | Change |
| --- | --- | ---: | ---: | ---: | ---: |
| Small | RSpec / ordinary | 1 | 0.5608 | 0.5651 | +0.8% |
| Small | RSpec / ordinary | 3 | 0.5619 | 0.5703 | +1.5% |
| Small | RSpec / shared examples | 1 | 0.5565 | 0.5718 | +2.7% |
| Small | RSpec / shared examples | 3 | 0.5650 | 0.5733 | +1.5% |
| Small | Minitest / ordinary | 1 | 0.5369 | 0.5447 | +1.5% |
| Small | Minitest / ordinary | 3 | 0.5542 | 0.5585 | +0.8% |
| Large | RSpec / ordinary | 1 | 1.4852 | 1.4792 | −0.4% |
| Large | RSpec / shared examples | 1 | 1.8346 | 1.8008 | −1.8% |
| Large | Minitest / ordinary | 1 | 1.1262 | 1.1397 | +1.2% |

Every unaffected median stays below the 5% regression gate in both profiled
and normal CLI runs. Three samples on one machine bound this conclusion;
small sub-millisecond minimizer phase differences are not useful speed claims.

Allocations did **not** improve. Large level-3 minimization allocations increased
from approximately 973,669 to 1,359,173 (+39.6%); total measured allocations
increased 8.3–10.8%. The accepted gate was at least 10% less targeted time **or**
allocations, and passes on time. Allocation count does not measure retained
bytes or peak memory. Peak process RSS is `null` with source `unavailable`
because Fiddle is absent from this Ruby 4 bundle; a memory regression has not
been ruled out. The benchmark retains `getrusage` measurements where available.

## Behavior and verification

All 36 profiled and 36 normal CLI report pairs match, including exit status.
The comparator preserves semantic IDs, order, counts, owners/phases, witness
pairs, minima/statuses/bounds/visited counts, diagnostics and completeness.
Only enumerated run IDs, capture timestamps and fixture-root paths are
normalized. Multi-run artifacts are rejected rather than collapsing their
run relationships.

Full-result regressions passed against both production sources. An independent
generated differential comparison matched 14,604 complete results from 1,000
cases spanning objectives, scopes, missing/unattributed evidence, canonical
ties, string/symbol inputs and exact/node/candidate limits. Focused tests retain
the brute-force oracle and cover mutable input between calls and greedy ties.

The full core suite passed: 1,703 tests, 241,851 assertions, zero failures or
errors, 13 optional integration skips. RuboCop passed on 187 files. Two benchmark
assertion block bindings were corrected afterward; the focused benchmark suite
(6 tests, 40 assertions) and touched-file lint passed again. RBS parsed and
validated with a temporary declaration of external `Rake::TaskLib`, whose
dependency signatures were unavailable. Production signatures did not change.
Luna spec and quality reviews approved the benchmark and minimizer changes.

## Reproduction

Use the same Ruby 4.0.1 executable, bundle and fixture directory for both trees.
Run the baseline at `f370702` and the candidate serially, alternating order for
three repetitions. Use distinct artifact directories for each repetition.

From each worktree (replace `baseline` with `candidate` for the other tree):

```sh
EXAMPLES=2000 DECISIONS=100 REPEATS=1 FRAMEWORKS=rspec,minitest SUITES=ordinary,shared LEVELS=1,3 PIPELINE_FIXTURE_DIR=/private/tmp/branchproof-fixture ARTIFACT_DIR=/private/tmp/baseline-large-1 bundle exec ruby benchmark/pipeline.rb
```

Repeat with `EXAMPLES=2 DECISIONS=1` for the small workload. Compare matching
artifact directories from the candidate tree:

```sh
bundle exec ruby benchmark/support/report_equivalence.rb /private/tmp/baseline-large-1 /private/tmp/candidate-large-1
```

For normal CLI wall measurements, run from the generated fixture directory,
pointing `BUNDLE_GEMFILE` and the executable/lib paths at each variant. For
example (substitute the absolute candidate tree path):

```sh
BUNDLE_GEMFILE=/absolute/candidate/Gemfile bundle exec ruby -I/absolute/candidate/lib /absolute/candidate/exe/branchproof analyze 'lib/**/*.rb' --framework rspec --test spec/policy_spec.rb --format json --level 3 --no-config -- --order defined --seed 1234
```

Use `spec/shared_policy_spec.rb` for shared examples; for Minitest use
`--framework minitest --test 'test/**/*_test.rb'` and only `--seed 1234` after
`--`. Capture monotonic elapsed time around each subprocess. Compare complete
JSON reports plus exit status through `ReportEquivalence.equivalent?` before
accepting a sample. Median calculations use the middle sorted value of three.
