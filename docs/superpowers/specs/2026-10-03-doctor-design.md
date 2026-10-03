# Static setup diagnostics

Add `branchproof doctor [SOURCE_GLOB ...] [--test TEST_GLOB] [--project auto|ruby|rails]
[--framework auto|minitest|rspec] [--config PATH|--no-config] [--format terminal|json]`.
The default format is terminal. Help is available without inspecting the project.
Doctor writes only to stdout and returns 0 when static checks pass, 2 when setup
is blocked or arguments are invalid. Warnings alone do not block. No output file,
runner arguments, analysis filters, thresholds or automatic repair options.

## Behavior

- Use the same configuration precedence, project/framework resolution, test
  discovery and source safety exclusions as analyze. Display resolved project,
  config path/defaults/disabled state, selection patterns, excludes and source/test
  counts. Configured coverage minima can be disclosed but are not evaluated.
- Check current Ruby engine/version against CRuby >= 4.0. Check only the selected
  framework, using gem metadata without requiring framework code: Minitest
  >= 5.25.5, < 6; rspec-core ~> 3.13.0. Prefer the activated gem specification;
  otherwise inspect visible RubyGems specs, choosing the highest visible version.
  Honor the active Bundler environment; never broaden its visible gem paths.
  Record whether the version was activated or merely discoverable. Availability
  is a metadata check, not a claim that framework loading will succeed.
- Missing/unsupported framework, invalid config, ambiguous framework selection,
  invalid Rails layout, no selected source files, or no discovered test files
  produce actionable blocking diagnostics. Independently check runtime and
  framework/discovery where resolved setup permits; a setup parse failure may
  produce a single setup diagnostic plus runtime information.
- Warn about already-loaded Spring/Bootsnap only when detectable from this
  process's loaded features; mere gem installation is not a conflict. No scan or
  execution of Ruby helper/config files. Disclose that runtime loader conflicts
  and application/test behavior remain unverified.
- Always say this is a static check: application boot, actual test discovery by
  the framework, runner compatibility, source syntax/instrumentation and coverage
  are not verified. A discovered test file need not contain executable tests.
- Never invoke Worker, Source#inventory, instrumentation, application boot,
  framework require, tests, Rake, or subprocesses. Never create artifacts or
  change environment variables, load paths, or project files. Existing core
  dependency loading remains unchanged; doctor requires Branchproof itself to
  be loadable and is not an emergency launcher for unsupported Ruby versions.

## Output contract

Use a distinct JSON document with `schema_version: 1`, `command: "doctor"`,
`status: "ready"|"blocked"`, runtime information, resolved project/configuration
and selection where available, selected framework metadata, `checks`, and
`limitations`. Each check has a stable `code`, `status` (pass/warning/error), and
human-readable `message`. A ready result means static checks passed only.
Errors requested with `--format json`, including config/project/CLI errors, must
still be one parseable JSON document on stdout with exit 2, not a coverage report.
Terminal output must include the same facts and an explicit static-only caveat.

## Implementation boundaries

Keep CLI parsing/configuration resolution as the single source of truth. A doctor
argument allowlist can delegate to the existing analyze parser. Extract only the
source selection from CLI#build_inventory into a helper used by both paths; keep
analyze behavior unchanged and protect it with regression tests before extraction.
Do not introduce a generalized command framework or new dependency. Put diagnostic
checks/rendering in `lib/branchproof/doctor.rb`, autoload Doctor, and update RBS.
No Rails or Minitest support-range expansion, collation or SimpleCov changes.

## Acceptance

Cover Ruby/Minitest, Ruby/RSpec and Rails layouts; CLI/config/default precedence;
excluded/helper/test/loaded source paths; empty selections; missing and unsupported
frameworks; malformed config and ambiguous projects; bad CLI options; valid JSON
on blocked runs; warning-only success; and help. Subprocess fixtures containing
source/helper/test/Rails boot markers must remain unexecuted. Compare project
file contents and relevant process state before/after; prove Source#inventory and
worker are never called. Extend actual installed-gem isolated consumer checks for
missing-framework doctor output. Run full tests/lint, RBS validation, docs and all
five CI lanes before claiming completion.
