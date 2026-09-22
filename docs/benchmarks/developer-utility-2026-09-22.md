# Developer utility trial and pipeline benchmark

At 2,000 examples and 100 decisions, level 3's measured minimization phase is
the largest pipeline phase: 8.883 s for ordinary RSpec and 8.852 s for shared
RSpec. All 60 synthetic matrix runs passed their report-count and minimization
checks, and all 18 application trial runs passed native parity validation.
The measurements below use only the final application and pipeline JSONL
records.

The application trials completed successfully for both selected fixtures. The
Agent ACL native baseline recorded 134 tests, 1,533 assertions, and 3 skips in
each repetition; instrumented levels 1 and 3 matched those counts and passed
their Branchproof baseline checks. The internal Rails fixture recorded 3 tests,
6 assertions, and no skips in each native and instrumented repetition; both
instrumented levels passed. The medians and min–max ranges are:

| Case | Wall seconds | Allocated objects | Largest process RSS |
| --- | ---: | ---: | ---: |
| Agent ACL native | 41.915 (41.780–41.955) | 35,615,150 (35,615,017–35,615,164) | 58.7 MiB (57.9–59.4) |
| Agent ACL level 1 | 42.788 (42.773–42.927) | 37,469,301 (37,469,233–37,469,464) | 78.0 MiB (77.6–78.2) |
| Agent ACL level 3 | 43.954 (43.795–44.124) | 37,595,448 (37,595,374–37,595,519) | 77.6 MiB (77.5–79.9) |
| Internal Rails native | 0.593 (0.587–0.792) | 468,681 (468,676–468,684) | 72.8 MiB (72.6–73.9) |
| Internal Rails level 1 | 1.056 (0.998–1.149) | 745,098 (745,085–745,098) | 75.7 MiB (75.5–75.8) |
| Internal Rails level 3 | 0.997 (0.994–1.003) | 746,686 (746,684–746,687) | 75.2 MiB (75.2–76.0) |

The instrumented Agent ACL runs each discovered 394 supported decisions with
275 eligible conditions and proved 41 conditions under the selected report
criteria. The Rails fixture each discovered 2 supported decisions with 2
eligible conditions and proved 1.

This record covers the developer utility changes on 2026-09-22: repeatable
project configuration, coverage policy evaluation, focused missing-coverage
reports, and the pipeline phase instrumentation. It combines application
trials with the synthetic pipeline harness. The application trials were run
from disposable scratch copies; the repository and third-party checkouts were
not modified by the timed commands.

## Frozen revisions and environment

- Branchproof: `d242947bab3b336e7c0e3d9c5438a9bb30a08bbd` (`0.10.0`), with the
  tracked source tree clean for the timed trial set. The benchmark document
  itself is an untracked work product and is not loaded by the trials.
- Agent ACL: `ae23cf4c2d4d68e9018c0486237838874d9871d6` on `main`, clean.
- Ruby: 3.4.7 (`7a5688e2a2`), CRuby + Prism, arm64 Darwin.
- Repetition count: three sequential runs per case and level.
- Application test runner seed: `1234` for every native and instrumented
  invocation. The synthetic RSpec matrix uses each generated fixture's default
  defined order and does not pass this seed.
- No warm-up run was discarded. Cases were run serially to avoid competing
  benchmark processes.

Each case used its own disposable lockfile while resolving the same local
Branchproof revision. The activated versions recorded by the probe were:

| Case | Core activated dependencies |
| --- | --- |
| Agent ACL | agent-acl 0.1.0, branchproof 0.10.0, bundler 4.0.19, minitest 5.27.0, prism 1.9.0, zeitwerk 2.8.3 |
| Internal Rails fixture | branchproof 0.10.0, rails/railties and Rails components 8.1.3.1, bootsnap 1.24.6, bundler 4.0.19, minitest 5.27.0, prism 1.9.0, zeitwerk 2.8.3 |

The synthetic pipeline used the unchanged worktree `Gemfile.lock`: Bundler
4.0.19, RSpec 3.13.2 with rspec-core 3.13.6, rspec-expectations 3.13.5,
rspec-mocks 3.13.8, and rspec-support 3.13.7, plus Prism 1.9.0 and Minitest
5.27.0.

The probe records the loaded dependency metadata after its JSON/Fiddle
collector setup; that metadata includes collector libraries and is not a
complete inventory of every application require. The table lists the versions
that affect the trial runner and framework integration. The same bundle is used
for the native and Branchproof command for each case. Agent ACL native and
instrumented runs share the identical disposable `Gemfile.trial` and
`Gemfile.trial.lock`, and the Rails native and
instrumented runs share the identical disposable `Gemfile` and `Gemfile.lock`.

## Source and command scan record

The timed command set was frozen in the scratch harness
`scripts/full_trials.rb`, with the command details retained in its
`metadata/deferred-commands.md` companion. The selected source and test paths
were:

| Case | Native command shape | Instrumented command shape |
| --- | --- | --- |
| Agent ACL | `bundle exec ruby -Ilib:test -e 'Dir["test/**/*_test.rb"].sort.each { \|f\| require File.expand_path(f) }' -- --seed 1234` | `bundle exec branchproof analyze 'lib/**/*.rb' --project ruby --level {1,3} --test 'test/**/*_test.rb' --format json --output ... -- --seed 1234` |
| Internal Rails fixture | `bundle exec ruby -Itest -I. -e 'require File.expand_path("config/environment"); require File.expand_path("test/fixture_rails_test")' -- --seed 1234` | `bundle exec branchproof analyze 'app/**/*.rb' --project rails --level {1,3} --format json --test 'test/fixture_rails_test.rb' --output ... -- --seed 1234` |

The Agent ACL trial scans all `lib/**/*.rb` and selects all
`test/**/*_test.rb`. The Rails trial scans only the copied fixture's
`app/**/*.rb` and selects only `test/fixture_rails_test.rb`. Native commands
and instrumented commands therefore exercise the same selected test files and
seed. The timed harness invokes the local checkout's absolute `exe/mcdc`
path; `bundle exec branchproof` above is the equivalent reproducible command
when the local path dependency is installed in the disposable bundle. The
Rails scratch copy uses the same disposable Gemfile and lockfile for native
and instrumented runs, with the trial-only `config.hosts << "www.example.com"`
allowance applied to that copy. The Rails case is an internal Branchproof
fixture copied from `test/fixtures/rails_app`; it is not an external Rails
application trial.

Levels 1 and 3 use the normal CLI report path. In the application trials,
level 3 includes the native minimization calls and does not change the
selected tests or seed. The synthetic matrix uses the same generated fixture
per group at each level and its default defined order. The harness checks
native and instrumented test-run counts, failures, and skips for each matching
repetition and records the Branchproof decision and completeness metrics in
the JSON artifact.

## Measurement definitions

For each fresh subprocess, wall time is measured with Ruby's monotonic clock
around the complete command. It includes process startup, Bundler and
framework loading, test execution, Branchproof instrumentation, evidence
collection, report construction, and process exit. It is an end-to-end
feedback-time measurement, not an isolated adapter or analyzer benchmark.

The allocation probe records `GC.stat(:total_allocated_objects)` and
`getrusage` peak resident memory for every Ruby process. Reported allocation
totals sum the measured processes. Reported peak RSS is the largest individual
process peak; it is not the simultaneous process-tree footprint and child RSS
is not added to the parent RSS. Wall time and peak RSS include process exit and
collector work. Application-trial allocation totals use the probe's counter
captured before its exit helper runs; the pipeline probe subtracts its counter
at probe load so its phase and process allocation figures exclude probe setup.
Medians and ranges are computed across the three repetitions for each case.

The synthetic pipeline harness (`benchmark/pipeline.rb`) additionally measures
inventory, worker, analysis, minimization, and rendering phases. The worker
interval includes child-process startup and test execution. Its phase wall
times are disjoint; do not sum a child phase into the worker phase. The
unmeasured remainder is total wall time minus the measured phase total and
includes startup, parsing, evidence merging, report setup, process exit, and
other orchestration. Pipeline output records verified report status, decision,
vector, and test counts for every run.

The required synthetic matrix command is:

```sh
MATRIX=1 FRAMEWORKS=rspec SUITES=ordinary,shared LEVELS=1,3 REPEATS=3 \
  bundle exec ruby benchmark/pipeline.rb
```

It contains five example/decision scenarios, ordinary and shared RSpec suites,
two report levels, and three repetitions: 60 timed runs. The pipeline's
Minitest path was smoke-verified separately; application measurements use the
real Minitest suite and the internal Rails fixture described above.

## Pipeline results and interpretation

All 60 RSpec matrix runs passed their report-count and minimization checks. The
matrix contains the five requested example/decision scenarios, ordinary and
shared suites, levels 1 and 3, and three repetitions. Totals below report
median (min–max) across each three-run group. RSS is MiB; allocation counts
are objects.

| Suite | Level | Examples/decisions | Wall seconds | Allocations | Largest process RSS | Phase total seconds | Remainder seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ordinary | 1 | 100/100 | 0.737 (0.710–0.754) | 923,521 (923,521–923,522) | 57.1 (56.5–58.6) | 0.423 (0.411–0.431) | 0.314 (0.299–0.323) |
| shared | 1 | 100/100 | 0.717 (0.712–0.723) | 953,576 (953,510–953,585) | 56.5 (56.1–57.1) | 0.425 (0.422–0.427) | 0.295 (0.286–0.298) |
| ordinary | 3 | 100/100 | 0.706 (0.702–0.716) | 953,107 (953,063–953,109) | 59.1 (57.7–59.7) | 0.411 (0.406–0.418) | 0.295 (0.295–0.299) |
| shared | 3 | 100/100 | 0.716 (0.714–0.792) | 983,162 (983,161–983,169) | 59.6 (59.6–59.9) | 0.432 (0.424–0.446) | 0.290 (0.284–0.346) |
| ordinary | 1 | 500/100 | 0.866 (0.859–0.914) | 1,374,082 (1,374,043–1,374,128) | 68.3 (67.7–70.4) | 0.530 (0.514–0.540) | 0.345 (0.335–0.374) |
| shared | 1 | 500/100 | 0.915 (0.913–0.938) | 1,524,251 (1,524,229–1,524,259) | 70.1 (69.9–70.1) | 0.581 (0.571–0.592) | 0.343 (0.334–0.346) |
| ordinary | 3 | 500/100 | 2.731 (2.704–2.737) | 1,924,552 (1,924,530–1,924,723) | 102.8 (102.0–104.4) | 2.378 (2.361–2.396) | 0.343 (0.341–0.353) |
| shared | 3 | 500/100 | 2.766 (2.728–2.780) | 2,074,835 (2,074,809–2,074,845) | 126.1 (126.1–128.1) | 2.408 (2.386–2.416) | 0.349 (0.342–0.373) |
| ordinary | 1 | 2000/10 | 1.340 (1.298–1.416) | 2,356,054 (2,355,759–2,356,543) | 91.1 (89.5–91.4) | 0.869 (0.817–0.941) | 0.475 (0.471–0.482) |
| shared | 1 | 2000/10 | 1.646 (1.626–1.710) | 2,954,478 (2,954,360–2,954,511) | 108.5 (108.4–108.7) | 1.160 (1.142–1.206) | 0.486 (0.484–0.504) |
| ordinary | 3 | 2000/10 | 1.502 (1.455–1.612) | 2,616,638 (2,614,829–2,616,669) | 95.1 (94.4–96.4) | 1.025 (0.994–1.092) | 0.478 (0.461–0.520) |
| shared | 3 | 2000/10 | 1.854 (1.761–1.900) | 3,214,552 (3,211,559–3,214,739) | 107.0 (106.9–108.4) | 1.355 (1.297–1.434) | 0.466 (0.464–0.499) |
| ordinary | 1 | 2000/50 | 1.437 (1.436–1.640) | 2,651,201 (2,647,763–2,652,689) | 94.8 (92.7–94.9) | 0.924 (0.911–1.142) | 0.512 (0.498–0.526) |
| shared | 1 | 2000/50 | 1.655 (1.634–1.703) | 3,252,302 (3,251,881–3,252,313) | 110.9 (110.5–111.3) | 1.162 (1.147–1.191) | 0.493 (0.487–0.511) |
| ordinary | 3 | 2000/50 | 3.847 (3.846–3.857) | 3,592,390 (3,592,333–3,592,427) | 114.4 (109.3–114.6) | 3.317 (3.313–3.322) | 0.529 (0.525–0.544) |
| shared | 3 | 2000/50 | 4.234 (4.081–4.783) | 4,191,660 (4,191,559–4,191,753) | 113.1 (112.9–113.5) | 3.728 (3.588–4.176) | 0.505 (0.493–0.607) |
| ordinary | 1 | 2000/100 | 1.482 (1.477–1.654) | 3,023,185 (3,023,061–3,023,462) | 97.0 (96.1–98.3) | 0.957 (0.944–0.970) | 0.533 (0.525–0.684) |
| shared | 1 | 2000/100 | 1.709 (1.698–1.713) | 3,623,401 (3,623,330–3,623,404) | 112.9 (110.5–113.1) | 1.191 (1.177–1.191) | 0.520 (0.518–0.523) |
| ordinary | 3 | 2000/100 | 10.332 (10.283–10.431) | 4,985,796 (4,985,449–4,985,821) | 170.7 (170.3–171.2) | 9.791 (9.730–9.902) | 0.542 (0.528–0.553) |
| shared | 3 | 2000/100 | 10.580 (10.579–10.597) | 5,585,663 (5,585,647–5,585,692) | 172.1 (171.5–172.7) | 10.050 (10.047–10.056) | 0.533 (0.523–0.547) |

For the 2,000-example/100-decision scenario, the phase medians and ranges are:

| Suite | Level | Inventory seconds | Worker seconds | Analysis seconds | Minimization seconds | Rendering seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ordinary | 1 | 0.014 (0.014–0.016) | 0.819 (0.813–0.832) | 0.016 (0.016–0.017) | — | 0.104 (0.101–0.108) |
| ordinary | 3 | 0.015 (0.014–0.016) | 0.784 (0.764–0.785) | 0.017 (0.016–0.019) | 8.883 (8.799–8.970) | 0.114 (0.112–0.115) |
| shared | 1 | 0.015 (0.014–0.015) | 1.050 (1.042–1.058) | 0.017 (0.016–0.017) | — | 0.104 (0.100–0.110) |
| shared | 3 | 0.015 (0.014–0.016) | 1.056 (1.052–1.090) | 0.016 (0.016–0.016) | 8.852 (8.795–8.857) | 0.114 (0.112–0.132) |

At 2,000 examples and 50 decisions, level 3 minimization is 2.443 s
(2.436–2.448) for ordinary and 2.492 s (2.399–2.948) for shared. Level 1
has no minimization phase; its worker interval is the largest measured phase
in the 2,000-example groups. This nominates level-3 minimization as the next
measured optimization target for this synthetic workload; the result does not
explain its cause or show that an optimization exists.

The compact per-run records, including all phase values, process measurements,
counts, revisions, and loaded dependency metadata without embedded reports or
absolute scratch paths, are in
[`docs/benchmarks/data/developer-utility-2026-09-22.json`](data/developer-utility-2026-09-22.json).

## Boundaries and exclusions

- No external Rails application was available or measured. Rails conclusions
  are limited to the internal fixture copy described above.
- No browser driver, external gem corpus, production application, or parallel
  execution workload is represented.
- An earlier probe attempt was excluded because startup Fiddle output polluted
  native stderr assertions; a follow-up collector attempt activated a JSON
  version that conflicted with the trial bundle. The final probe captured
  native counts without stderr output and is the only application dataset used
  here. Neither excluded attempt contributes metrics.
- Synthetic pipeline fixtures are intentionally small and controlled; their
  phase proportions must not be generalized to application-scale workloads.
- Full embedded Branchproof reports, test stdout, and scratch absolute paths
  are excluded from committed evidence. Compact per-run JSON may retain case,
  revision, dependency versions, counts, timings, phase summaries, and
  process-level allocation/RSS values without report bodies or sensitive paths.
- The measurements establish observed behavior for the frozen revisions and
  environment only.
