# jekyll-agent-markdown Branchproof trial

## Scope

- Original repository: `/Users/luciang/Dropbox/workprojects/opensource/jekyll-plugins/jekyll-agent-markdown`
- Revision: `d524eb2a19ac819ddc6215ab47d07c8444005442`
- Original status: clean (`git status --porcelain=v1` empty)
- Disposable target: `/private/tmp/branchproof-jekyll-trial`
- Ruby: `3.4.5` (`/Users/luciang/.rubies/ruby-3.4.5/bin/ruby`)
- Test framework: native Minitest via `Rakefile`/`minitest/test_task`
- Dependency bundle: `/private/tmp/branchproof-jekyll-trial-gems`
- Resolved versions: Bundler `4.0.19`, Minitest `5.26.2`, Jekyll `4.4.1`, Rake `13.4.2`, Prism `1.9.0`, Branchproof `0.2.0`.
- Locale for final runs: `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`; `Encoding.default_external` and filesystem encoding were both UTF-8.
- Branchproof: local source dependency at `.../decisive/gems/decisive`, version `0.2.0`; no Branchproof source was changed.

The original gem checkout was copied before testing. The copy adds only a disposable `branchproof` Gemfile entry and one disposable targeted test. No original gem files were changed.

## Native baseline

Command:

```text
env -i PATH=/Users/luciang/.rubies/ruby-3.4.5/bin:/usr/bin:/bin:/opt/homebrew/bin HOME=/Users/luciang LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 GEM_HOME=/private/tmp/branchproof-jekyll-trial-gems GEM_PATH=/private/tmp/branchproof-jekyll-trial-gems bundle exec ruby -Ilib:test -e 'Dir["test/**/*_test.rb"].reject { |path| path == "test/branchproof_targeted_test.rb" }.sort.each { |path| require_relative path }' -- --seed 1234
```

The initial `env -i` run omitted locale variables and produced an ASCII-8BIT/US-ASCII environment; that run reported two encoding failures and is retained only as a setup diagnostic. With the explicit UTF-8 locale and seed `1234`, the native baseline passed: 192 runs, 1,155 assertions, 0 failures, 0 errors, 0 skips, 8.27 seconds.

The two previously observed encoding failures both pass under the explicit UTF-8 locale. This establishes the failures as trial-environment artifacts rather than gem defects.

## Seeded Branchproof runs

Narrow command:

```text
bundle exec mcdc analyze 'lib/jekyll/agent_markdown/*.rb' --project ruby --test test/jekyll/agent_markdown_test.rb --format json --output tmp/branchproof-narrow-utf8.json -- --seed 1234
```

With the explicit UTF-8 locale, the narrow run passed: 101 tests, 0 failures, 0 skips. It discovered 106 decisions: 100 supported, 6 unsupported ternaries, 114 eligible conditions, 11,737 completed observations, 8 aborted observations, 77 proven conditions, and 67.54% coverage. Artifact: `/private/tmp/branchproof-jekyll-trial/tmp/branchproof-narrow-utf8.json`.

Full comparable command:

```text
bundle exec mcdc analyze 'lib/**/*.rb' --project ruby --test 'test/**/*_test.rb' --format json --output tmp/branchproof-full-utf8.json -- --seed 1234
```

This 192-test full run was performed before the disposable targeted test was added; the targeted test was then kept outside the project `test/` tree so the command remains comparable. With the explicit UTF-8 locale, the full run passed: 192 tests, 1,155 assertions, 0 failures, 0 skips, 13,235 completed observations, 93 proven conditions out of 114 eligible conditions, and 81.58% coverage. Artifact: `/private/tmp/branchproof-jekyll-trial/tmp/branchproof-full-utf8.json`.

The instrumented suite passes under the same corrected environment as the native suite. No Branchproof-induced test failure was observed.

## Manual supported-decision inventory

Direct Prism/Branchproof inventory of the unchanged source identified supported compound decisions, including:

- `lib/jekyll/agent_markdown/configuration.rb:30` — `settings.nil? || settings == true`; both conditions are `PROVEN`. Witnesses include `[true, nil] => true`, `[false, false] => false`, and `[false, true] => true`, owned by the existing configuration and generator tests.
- `lib/jekyll/agent_markdown/raw_markdown_file.rb:50` — `root_relative?(decoded_path) && !decoded_path.split("/").include?("..")`; both conditions are `PROVEN`. Witnesses include `[true, true] => true`, `[true, false] => false`, and `[false, nil] => false`, including `test_rejects_paths_that_can_escape_the_destination`.
- `lib/jekyll/agent_markdown/llms_index_renderer.rb:85` — `value.nil? && source.respond_to?(:excerpt)`; both conditions become `PROVEN` in the targeted rerun. The targeted test supplies `[true, true] => true` and `[true, false] => false`; the existing suite supplies `[false, nil] => false`.

The six unsupported decisions are ternary expressions and are reported with `unsupported_ternary` diagnostics. The remaining unproven conditions represent missing effective-sign observations, rather than a failed test run.

## Targeted missing case

Disposable file added: `/private/tmp/branchproof-jekyll-targeted.rb`.

It exercises `Configuration.enabled?` with `{}` and `{ "posts" => false }`, then directly covers the missing excerpt fallback branch in `LlmsIndexRenderer#description_value`. Under the corrected UTF-8 environment the rerun passed with 103 tests and improved the narrow result from 77/114 proven conditions (67.54%) to 78/114 (68.42%); the new `[true, true]` and `[true, false]` witnesses prove `llms_index_renderer.rb:85`. Artifact: `/private/tmp/branchproof-jekyll-trial/tmp/branchproof-targeted-utf8.json`.

## Remaining coverage

The trial is complete under Ruby 3.4.5, Jekyll 4.4.1, and the explicit UTF-8 locale. Remaining risk is semantic coverage: 37 conditions are still unproven in the narrow run, 21 in the full run, and six ternary decisions are outside the current supported syntax. Timings are indicative run durations, not benchmarks; no overall instrumentation overhead measurement was taken.
