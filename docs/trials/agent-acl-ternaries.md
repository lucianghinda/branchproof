# Branchproof ternary follow-up: agent-acl

This follow-up reused the clean matched disposable copy at `/private/tmp/branchproof-agent-acl-equivalent`, with the original `agent-acl` Gemfile plus a local Branchproof path dependency. It preserved the inherited real `HOME` and used `BUNDLE_USER_HOME=/private/tmp/branchproof-agent-acl-bundle-user`, Ruby 3.4.5, Bundler 4.0.12, Minitest 5.27.0, and the existing isolated dependency home `/private/tmp/decisive-v2-ruby3.4-gemhome`. The previously verified native baseline remains 134 tests, 1,533 assertions, 0 failures, 0 errors, and 3 skips at seed 1234; it was not rerun because source and target tests were unchanged.

The exact command was:

```sh
export PATH=/Users/luciang/.rubies/ruby-3.4.5/bin:/usr/bin:/bin
export GEM_HOME=/private/tmp/decisive-v2-ruby3.4-gemhome
export GEM_PATH=/private/tmp/decisive-v2-ruby3.4-gemhome
export BUNDLE_GEMFILE=/private/tmp/branchproof-agent-acl-equivalent/Gemfile
export BUNDLE_USER_HOME=/private/tmp/branchproof-agent-acl-bundle-user
cd /private/tmp/branchproof-agent-acl-equivalent
bundle exec mcdc analyze 'lib/**/*.rb' --project ruby \
  --test 'test/**/*_test.rb' --format json \
  --output /private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-full-ternaries.json \
  -- --seed 1234
```

The run passed with 134 tests, 1,533 assertions, 0 failures, 0 errors, and 3 skips. Minitest reported 30.929 seconds; a Ruby `Open3` harness measured 32.400 seconds total wall clock, including Bundler startup, inventory, instrumentation, analysis, and report writing. These are single-run timings, not benchmarks. The exact JSON artifact is `/private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-full-ternaries.json`; captured stdout/stderr are `ternaries-wallclock.stdout` and `ternaries-wallclock.stderr` in the same directory.

Ternary support behaved as expected. The report discovered 157 decisions, all 157 supported, with 0 unsupported decisions or conditions, 185 eligible conditions (up from 165), 4 opaque conditions, 108 unexecuted decisions, 1,675 completed observations, 1 unattributed observation, and 38 proven conditions (20.54%, up from 28 / 16.97%). The only diagnostic was one informational `not_instrumented` result for a source unit with no safe edits. The inventory contains 20 ordinary `?:` ternaries, all labeled `context: "ternary"` and `support_status: "SUPPORTED"`.

Two observed ternary decisions provide concrete ownership evidence. In `lib/agent_acl/installers/claude_code.rb:22`, `manifest.entries.empty?` had `[true] -> true` witnesses owned by `test_claude_code_sync_removes_its_hook_when_nothing_is_protected` and related macOS integration tests, and `[false] -> false` witnesses owned by `test_claude_code_install_merges_foreign_content_and_is_idempotent` plus other installer tests; the condition was proven. In `lib/agent_acl/installers/codex.rb:42`, `add_managed_hook` had `[true] -> true` and `[false] -> false` witnesses owned by `test_sync_preserves_an_identical_codex_hook_that_preceded_agent_acl`, `test_codex_install_merges_foreign_hooks_and_sync_removes_only_the_managed_hook`, and `test_block_and_allow_wire_every_layer_on_macos`; the condition was proven. A third observed example, `lib/agent_acl/installers/opencode.rb:40` (`owned_paths.empty?`), also had both truth values and was proven.

The prior full artifact remains at `/private/tmp/branchproof-agent-acl-equivalent/tmp/branchproof-full.json`; this follow-up writes only the new ternary artifact and does not modify Branchproof or the original `agent-acl` repository.
