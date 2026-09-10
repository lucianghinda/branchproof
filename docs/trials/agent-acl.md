# Branchproof trial: agent-acl

This trial used the clean `agent-acl` checkout at revision `ae23cf4c2d4d68e9018c0486237838874d9871d6` (`main...origin/main`, dirty status clean). The source was copied to `/private/tmp/branchproof-agent-acl-trial`; the original repository and Branchproof source were not modified. The trial ran on Ruby `3.4.5` (`+PRISM`, arm64-darwin24) with Branchproof `0.2.0` from the local source tree under `gems/decisive` and the existing matching dependency home `/private/tmp/decisive-v2-ruby3.4-gemhome`.

`agent-acl` uses Minitest through its Rake task. The equivalent trial preserved the original Gemfile and lockfile, adding only Branchproof as a local path gem. Reproduction uses this environment:

```sh
export PATH=/Users/luciang/.rubies/ruby-3.4.5/bin:/usr/bin:/bin
export GEM_HOME=/private/tmp/decisive-v2-ruby3.4-gemhome
export GEM_PATH=/private/tmp/decisive-v2-ruby3.4-gemhome
export BUNDLE_GEMFILE=/private/tmp/branchproof-agent-acl-equivalent/Gemfile
export BUNDLE_USER_HOME=/private/tmp/branchproof-agent-acl-bundle-user
cd /private/tmp/branchproof-agent-acl-equivalent
```

The installed versions were Ruby 3.4.5 (`+PRISM`, arm64-darwin24), Bundler 4.0.12, Minitest 5.27.0, Zeitwerk 2.8.3, RuboCop 1.84.2, YARD 0.9.45, and Branchproof 0.2.0 from `/Users/luciang/Dropbox/workprojects/opensource/decisive/gems/decisive`. The exact native baseline command was:

```sh
ruby -Ilib:test -e 'Dir["test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }' -- --seed 1234
```

The direct baseline completed in 26.556 s of Minitest-reported suite time with 134 runs, 1,533 assertions, 0 failures, 0 errors, and 3 skips. A matched Ruby `Open3` harness measured 30.080 s total wall-clock time for this baseline command, including Bundler startup and process setup. The equivalent Rake command, using Minitest 5.27's current argument variable, is:

```sh
A='--seed 1234' bundle exec rake test
```

It also passed with 134 runs, 1,533 assertions, 0 failures, 0 errors, and 3 skips (27.516 s of Minitest-reported suite time). Using the legacy `TESTOPTS='--seed 1234'` variable emits Minitest 5.27's deprecation warning, which the documentation-task test correctly captures as an unexpected stderr failure; that invocation is excluded from the comparable result. Timings are single-run observations, not benchmarks.

The first exploratory Branchproof bundle used only runtime dependencies and is retained separately in `/private/tmp/branchproof-agent-acl-trial`; it explains the earlier dependency-mismatch failures and is not the comparison result. The equivalent copy and exact locked dependency installation are described above.

The equivalent Branchproof narrow command was:

```sh
bundle exec mcdc analyze lib/agent_acl/os_guard.rb --project ruby \
  --test test/os_guard_test.rb --format json \
  --output tmp/branchproof-os-guard.json -- --seed 1234
```

The equivalent narrow trial passed its selected baseline (8 tests, 37 assertions, 0 failures, 0 errors, 0 skips) in 0.016 s of Minitest-reported suite time. It discovered 10 decisions / 15 eligible conditions, all 10 supported, with 1 opaque condition, 43 completed observations, 1 unexecuted decision, 8 proven conditions, and 53.33% reported coverage. The equivalent JSON artifact is `/private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-narrow.json`; the earlier exploratory artifact remains at `/private/tmp/branchproof-agent-acl-trial/tmp/branchproof-os-guard.json`.

The equivalent full command used `lib/**/*.rb` and `test/**/*_test.rb`. It completed in 29.662 s of Minitest-reported suite time with 134 tests, 1,533 assertions, 0 failures, 0 errors, and 3 skips; the matched Ruby `Open3` harness measured 36.074 s total wall-clock time including Bundler startup, inventory, instrumentation, analysis, and report writing. The Branchproof baseline was `PASSED`, with 157 decisions discovered, 137 supported, 20 unsupported ternaries, 165 eligible conditions, 4 opaque conditions, 99 unexecuted decisions, 1,504 completed observations, 1 unattributed observation, and 28 proven conditions (16.97%). The full equivalent artifact is `/private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-full-wallclock.json`. This is the valid same-bundle comparison; the earlier exploratory full artifact at `/private/tmp/branchproof-agent-acl-trial/tmp/branchproof-full.json` remains useful only as evidence of the dependency mismatch.

The reproducible full command (after the environment block above) is:

```sh
bundle exec mcdc analyze 'lib/**/*.rb' --project ruby \
  --test 'test/**/*_test.rb' --format json \
  --output /private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-full-wallclock.json \
  -- --seed 1234
```

Manual supported-decision inspection in `lib/agent_acl/os_guard.rb` showed useful ownership and masking detail. `line 65` (`linux? && locked && !root_user`) had a concrete vector `[false, nil, nil] -> false` owned by `test_unprotect_lifts_macos_flag_before_restoring_the_mode` / `test_unprotect_restores_mode_when_the_flag_was_lifted_by_hand`, and `[true, true, true] -> true` owned by `test_linux_allow_requires_root_when_immutable`; this proves `linux?` but leaves `locked` without an effective sign in the clean narrow run. `line 67` (`macos? && locked`) had a `[true, false] -> false` vector from `test_unprotect_restores_mode_when_the_flag_was_lifted_by_hand` and `[true, true] -> true` from `test_unprotect_lifts_macos_flag_before_restoring_the_mode`, proving `locked` while the `macos?` condition remained unproven. `line 91` (`macos? || linux?`) proved both conditions with `[false, false] -> false` from `test_rejects_an_unsupported_platform_before_changing_the_file`, `[true, nil] -> true` from the macOS tests, and `[false, true] -> true` from `test_linux_without_root_degrades_loudly` / related Linux tests. Each condition has source byte/line ownership and Minitest test IDs in the JSON report; no observation was unattributed in the narrow run.

To check that missing evidence can improve honestly, the disposable exploratory copy gained one targeted test, `test_linux_root_unprotect_lifts_the_immutable_flag`, covering the root Linux `linux? && locked` path. Rerunning the same narrow command produced 9 tests, 40 assertions, 0 failures, 0 errors, 0 skips; completed observations rose to 49 and proven conditions from 8 to 11 (73.33%). The updated decision statuses were: line 65 `PROVEN, NOT_PROVEN, PROVEN`; line 67 `PROVEN, PROVEN`; line 68 `PROVEN, NOT_PROVEN`; line 91 `PROVEN, PROVEN`. This demonstrates evidence attribution improving for the exercised path while correctly leaving the remaining `locked` effective-sign obligation unproven. Updated artifact: `/private/tmp/branchproof-agent-acl-trial/tmp/branchproof-os-guard-targeted.json`. The equivalent clean full comparison above excludes this targeted test.

No Branchproof source changes, commits, pushes, or publication actions were made. The equivalent full comparison is green; the only setup caveat is that callers using the deprecated `TESTOPTS` variable will see Minitest's warning and should use `A` as shown above.
