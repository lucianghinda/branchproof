# RSpec adapter benchmark

Run from the repository root with the supported bundle:

```sh
bundle exec ruby benchmark/rspec_adapter.rb
```

The harness defaults to 2,000 examples, 100 independent two-condition decisions,
and three fresh-process repetitions. It measures both ordinary examples and a
shared-example-heavy suite (2,000 contexts including the same shared example).
Every decision receives both true and false outcomes. An equivalent Minitest
suite is included as an additional instrumented reference.

Configure suite size and repetitions with environment variables:

```sh
EXAMPLES=5000 DECISIONS=250 REPEATS=5 bundle exec ruby benchmark/rspec_adapter.rb
EXAMPLES=2 DECISIONS=1 REPEATS=3 bundle exec ruby benchmark/rspec_adapter.rb
```

The JSON-lines output includes every run and min/median/max summaries. Execution
order rotates between repetitions to reduce order bias; there is no discarded
warmup. Wall time includes process startup, framework loading, test execution,
instrumentation, and report construction. These are end-to-end measurements,
not isolated adapter CPU measurements.

A `RUBYOPT` probe records allocations and `getrusage` peak resident memory in
each Ruby process. Allocations are summed across CLI and worker; reported peak
RSS is the **largest individual process peak**, not the simultaneous memory
footprint of the process tree. Per-process measurements remain in each JSON
record. Allocation counting starts after loading the probe's JSON and Fiddle
libraries. The probe uses Ruby 3.4's standard-library Fiddle and supports 64-bit
macOS/Linux; Fiddle must already be available to use the probe with newer Ruby.
No benchmark dependency is added to the project.

The instrumented results also record decision/vector/owner counts and fail if
the expected decision or owner counts are missing. Native RSpec produces no
Branchproof evidence, so those fields are unavailable rather than inferred.

## Repeated suite measurement

Measured on 2026-09-21 after the review fixes, Ruby 3.4.7 on macOS arm64,
using the default 2,000 examples / 100 decisions / three repetitions:

| Suite | Run | Median elapsed (min–max), seconds | Median allocations | Median largest-process peak RSS |
| --- | --- | ---: | ---: | ---: |
| Ordinary | Native RSpec | 0.4239 (0.3941–0.4386) | 350,013 | 48.2 MiB |
| Ordinary | Branchproof RSpec | 10.5148 (10.4392–10.7829) | 4,941,895 | 164.9 MiB |
| Ordinary | Branchproof Minitest | 10.0298 (9.9205–10.3380) | 4,524,600 | 156.0 MiB |
| Shared | Native RSpec | 0.6651 (0.6255–0.6856) | 933,888 | 81.1 MiB |
| Shared | Branchproof RSpec | 10.6368 (10.5273–10.6848) | 5,541,769 | 169.7 MiB |

All 15 runs exited successfully. Every instrumented run recorded 100 decisions,
200 vectors, and 2,000 owners; native selection counts were also checked.
The local machine was also running development verification, so these are
illustrative measurements rather than an isolated performance laboratory.

There is substantial end-to-end overhead on this synthetic workload. The CLI
and report-building process accounts for most allocations and the largest RSS
peak in the instrumented runs. The similar Minitest time suggests the shared
analysis/report pipeline deserves profiling, but this benchmark does not isolate
its individual costs. No before/after speedup is claimed: earlier measurements
overlapped edits and are not a controlled baseline. More suite sizes and real
application workloads are needed before making scalability claims.

## Original startup smoke measurement

Ruby 3.4.7, single run:

| Run | Elapsed | Child allocations | Decisions | Vectors | Owners | Exit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Native RSpec | 0.2469 s | 31,971 (1 process) | unavailable | unavailable | unavailable | 0 |
| Branchproof RSpec | 0.5472 s | 94,565 (CLI + worker) | 1 | 2 | 2 | 0 |
| Branchproof Minitest | 0.5391 s | 73,972 (CLI + worker) | 1 | 2 | 2 | 0 |

These original numbers establish only tiny-suite startup cost. They are not
evidence of suite scalability or directly comparable to the expanded fixture.
Rails, browser drivers, application boot, complex decisions, and broad corpus
performance require their own integration measurements. Synthetic suite results
must not be generalized to those workloads.

## Pipeline phase benchmark

`benchmark/pipeline.rb` measures the same synthetic ordinary and shared RSpec
fixtures, plus the ordinary Minitest fixture, in fresh subprocesses. Each run
records monotonic wall time and allocated objects for inventory, the worker,
analysis, minimization, and report rendering. The worker phase is the parent
CLI's `run_worker` interval, including child-process startup and test execution.
Rendering is measured at `Report#write`; the surrounding `CLI#output_report`
call is counted but has no second timer, so nested phase times are not
double-counted. Startup, parsing, evidence merging, report setup, and other
orchestration are the unmeasured remainder.
Minitest is intentionally measured only with the ordinary fixture; shared
suite measurements are RSpec-only. A shared-only Minitest selection is rejected.

Select Ruby 3.4.7 using your Ruby version manager, then run the bounded smoke
benchmark from the gem directory with its development bundle:

```sh
SMOKE=1 bundle exec ruby benchmark/pipeline.rb
```

The smoke run uses two examples, one decision, one repetition, levels 1 and 3,
ordinary/shared RSpec, and ordinary Minitest. Level 3 executes the native CLI
minimization path in full: two calls per decision plus one aggregate call;
coverage, evidence, and report output are unchanged. Every JSON-lines run record includes the
verified report status, decision/vector/test counts, per-phase measurements,
per-process allocations, largest individual process peak RSS, phase total, and
the explicit elapsed-time remainder. The remainder includes startup, parsing,
evidence merging, report setup, process exit, and any other unmeasured work;
phase totals are disjoint and do not include the surrounding `output_report`
wrapper. Peak RSS is not the simultaneous process-tree footprint. The Fiddle
probe is the same 64-bit macOS/Linux `getrusage` probe used by the RSpec adapter
benchmark.

Configuration is bounded with `EXAMPLES`, `DECISIONS`, `REPEATS`,
`LEVELS=1,3`, `FRAMEWORKS=rspec,minitest`, and `SUITES=ordinary,shared`.
`MATRIX=1` runs the five requested scenarios: 100, 500, and 2,000 examples at
100 decisions, then 2,000 examples at 10, 50, and 100 decisions. The exact
full matrix command is:

```sh
MATRIX=1 REPEATS=3 LEVELS=1,3 bundle exec ruby benchmark/pipeline.rb
```

This harness has no external Rails application trial. Rails, external gem, and
real application measurements require separate fixtures and are not claimed by
these synthetic results.

The [2026-09-22 measurement report](developer-utility-2026-09-22.md) records the
three-repeat ordinary/shared RSpec matrix, an external Minitest gem trial, and
an internal Rails fixture trial, with phase breakdowns and compact per-run data.
