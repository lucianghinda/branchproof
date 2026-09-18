# RSpec adapter benchmark

Run from the repository root with the supported bundle:

```sh
bundle exec ruby benchmark/rspec_adapter.rb
```

The standard-library harness creates an equivalent two-example plain Ruby
fixture, runs native RSpec, Branchproof RSpec, and Branchproof Minitest in
isolated child processes, and reports wall time plus allocations from a
`RUBYOPT` probe installed in each child. It also records the instrumented
report's decision/vector/owner counts. Native RSpec does not produce
Branchproof evidence, so those fields are reported as unavailable rather than
inferred.

Ruby 3.4.7, single run:

| Run | Elapsed | Child allocations | Decisions | Vectors | Owners | Exit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Native RSpec | 0.2469 s | 31,971 (1 process) | unavailable | unavailable | unavailable | 0 |
| Branchproof RSpec | 0.5472 s | 94,565 (CLI + worker) | 1 | 2 | 2 | 0 |
| Branchproof Minitest | 0.5391 s | 73,972 (CLI + worker) | 1 | 2 | 2 | 0 |

These are smoke measurements for adapter overhead on a tiny fixture, not a
large-suite performance claim. Rails, browser drivers, and broad corpus
performance require their own integration measurements.
