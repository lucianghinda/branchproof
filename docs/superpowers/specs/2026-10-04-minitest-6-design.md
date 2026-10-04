# Minitest 5 and 6 compatibility

## Approved outcome

Serial plain-Ruby applications using Minitest 6 can use Branchproof while
existing Minitest 5 applications retain their behavior. Support becomes
`>= 5.25.5, < 7`, subject to real acceptance runs at 5.26.2, the locked 5.27.0,
6.0.0, and 6.0.6. Runtime framework availability and doctor must agree.

The original 5.25.5 CI target was replaced after its published Ruby requirement
(`>= 2.7, < 4.0`) prevented installation on Branchproof's required Ruby 4.
The existing adapter version floor remains unchanged; upstream Ruby constraints
still determine which versions Bundler can resolve.

The application still supplies Minitest. No runtime dependency, new mock-library
dependency, report schema change, gem version bump, or SimpleCov work is included.
Existing Rails jobs remain on their tested Minitest 5 bundle; plain-Ruby Minitest
6 verification does not imply Rails/Minitest 6 support.

## Compatibility behavior

- Retain current instance `run`, `after_setup`, `before_teardown`, and `after_run`
  lifecycle hooks; upstream Minitest 6 retains these APIs.
- Preserve executed/failed/skipped counts, test ownership, setup/body/teardown
  attribution, seed propagation, discovery, and coverage gate exit behavior.
- Pass framework runner filters through: existing `--name` on both generations,
  and Minitest 6's `--include` where supported.
- Recognize both Minitest 5 `test_order` and Minitest 6 `run_order` parallel
  scheduling markers without treating an idle/default executor as active
  parallel testing. Preserve Rails executor safety.
- Reject bisect/server arguments and active server integration in addition to
  existing parallel/fork/custom-runner rejection, before test bodies execute.
  Do not broaden support to custom runner or framework plugin combinations.
- Keep activated gem metadata authoritative when checking versions; preserve
  missing-framework and unsupported-version diagnostic codes and completeness.

## Verification contract

The normal development bundle and full suite stay on Minitest 5. A selectable
`BRANCHPROOF_MINITEST_VERSION` test bundle enables dedicated real-consumer
acceptance under both generations. New CI jobs exercise exact versions and
assert the actually activated version before testing. Avoid importing
`minitest/mock` into Minitest 6 acceptance; it is no longer bundled upstream.

Real subprocess tests must demonstrate correct native/Branchproof counts,
observations and owners, filtered selection and seeds, failures/skips/empty runs,
parallel/custom/bisect/server rejection, doctor readiness without framework boot,
and passing/failing MC/DC gates. Reuse existing acceptance tests where they
already establish these behaviors. Installed-gem acceptance protects framework
optional dependencies and report-only consumers.

Sources: installed Minitest 5.27.0 and 6.0.x runner/test/parallel sources and
[upstream history](https://github.com/minitest/minitest/blob/master/History.rdoc).

## Baseline

Main `c987c3b` is clean. Before changes, Minitest adapter tests passed 5/20 and
CLI acceptance passed 18/117 on the locked Minitest 5 bundle.
