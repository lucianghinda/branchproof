# Branchproof 0.2.0: Minitest in Ruby and Rails projects

**Goal:** Run the existing Levels 1–3 analysis against ordinary Ruby Minitest projects and real Rails applications without editing application files.
**Architecture:** Keep the single isolated worker and native Ruby compilation hook. Resolve project configuration in the parent, establish the child environment before boot, then install instrumentation and Minitest lifecycle hooks before booting Rails or loading tests.
**Stack:** Existing Prism/Minitest runtime dependencies and Ruby standard library. Rails is supplied by the application; an optional Rails integration test bundle exercises compatibility.

## Decisions and scope

- User: “make commits and then go to the next version” — V1 is committed before this work; verified 0.2 work will also be committed.
- User: “focus on Minitest first and support either Rails or just Ruby projects” — both project types use the same Minitest adapter and analytical core.
- User: “Use Luna subagents for implementation and you should remain the orchestrator” — Luna agents own code; the orchestrator owns design, integration review, and final checks.
- Add `--project auto|ruby|rails`, default `auto`. Auto selects Rails only when both `config/application.rb` and `config/environment.rb` exist; an explicit Rails project lacking them is a usage error.
- Ruby projects inherit environment values. Rails child processes use `RAILS_ENV=test`, `RACK_ENV=test`, `PARALLEL_WORKERS=1`, `DISABLE_BOOTSNAP=1`, and `DISABLE_SPRING=1`. The parent environment is untouched.
- Default tests are the sorted, deduplicated union of `test/**/*_test.rb` and `test/**/test_*.rb`, excluding default helper/support/fixture files. Explicit `--test` selection remains authoritative. Child load paths include project `lib` and `test`.
- Rails boot uses the selected project's `config/environment.rb`, then `rails/test_help`, after runtime, loader, and adapter hooks exist. Normal application `test_helper` files continue to run once through native require caching.
- Support ordinary Zeitwerk lazy and eager loading in a single test run. Reload-enabled Rails configurations are rejected with a useful diagnostic; active incompatible compilation-hook owners and true parallel scheduling remain errors.
- Keep runtime Rails dependencies optional. Prove a real Rails 8.1 integration first; advertise only the versions actually checked. Do not substitute a mock Rails namespace or Zeitwerk-only fixture for Rails acceptance.
- Mutation, RSpec, forked/parallel workers, Rails system/browser tests, custom Rails test commands, and reloading are outside 0.2.

The alternative of invoking `bin/rails test` would add a second runner/bootstrap protocol and make once-only finalization harder to guarantee. A generic arbitrary boot-file option offers less useful project policy and is unnecessary for this release. The existing worker plus a small Rails boot boundary is the chosen approach.

## Shared contracts

`Project.new(root:, mode: "auto").to_h` returns a plain symbol-keyed configuration:

```ruby
{ kind: "rails", root: absolute_root,
  load_paths: [absolute_lib, absolute_test],
  environment: { "RAILS_ENV" => "test", "RACK_ENV" => "test",
                 "PARALLEL_WORKERS" => "1", "DISABLE_BOOTSNAP" => "1",
                 "DISABLE_SPRING" => "1" } }
```

Ruby configurations have `kind: "ruby"` and an empty environment override. CLI stores this in the private request as `project`, and passes the environment overrides to `Open3.capture3` rather than modifying parent `ENV`. Worker prepends the configured load paths. Rails configuration does not itself load Rails.

`MinitestAdapter#run` gains the optional keyword `before_load: nil`. It installs lifecycle and runner guards and its completion callback, enters the guarded loading phase, calls `before_load`, then requires test files. The worker supplies a Rails boot callback only for Rails projects.

The required order is `Runtime.boot → Loader#install → adapter hooks/completion callback → RailsSupport.boot → require test files → autorun`. Default discovery removes `test_helper.rb` and paths beneath `test/support/` and `test/fixtures/` after forming the sorted union. Explicit `--test` selection bypasses these default-only exclusions.

`RailsSupport.boot(project:)` requires the environment and `rails/test_help`, validates actual Rails initialization/test environment/non-reloading configuration, and returns report metadata including Rails version. Baseline `project` metadata records the selected kind and Rails policy. No evidence schema or criterion change is needed.

## Implementation lanes and acceptance

- [x] **Project configuration / CLI (Luna).** Own `project.rb`, `cli.rb`, entry-point require, `test_project.rb`, and `test_cli.rb`. Implement the configuration contract, option validation, deterministic test defaults, exact explicit test-file exclusions, child environment overrides, and request transport. Tests must prove both filename conventions, helper loaded once through `require "test_helper"`, source loaded through `require`, exact runner tokens, project override, invalid mode, and unchanged parent environment.
- [x] **Worker / Rails boot (Luna).** Own `worker.rb`, new `rails_support.rb`, and focused worker/boot tests. Install loader before Rails boot; use the new adapter callback; add project metadata. Reject malformed/uninitialized/reloading Rails configurations with actionable errors and no passing analysis. Preserve original plain Ruby payload behavior. Prove the configured boot callback runs after hook installation and before application tests.
- [x] **Minitest lifecycle and serial policy (Luna).** Own `minitest_adapter.rb` and adapter tests. Add the optional guarded boot callback, preserving exactly one native autorun. Replace name-based parallel heuristics with behavior/state checks that reject active Minitest parallel scheduling while accepting Rails workers=1. Test callback errors/custom runs, ordinary serial subclasses, actual parallel markers, and existing phase boundaries. Coordinate Rails API evidence with the integration lane.
- [x] **Real Rails integration (Luna).** Own `test/test_rails_integration.rb`, `test/fixtures/rails_app/**`, and any test-only support required by that file. Build a minimal real Rails application with Zeitwerk-loaded service/controller decisions and real `ActiveSupport::TestCase` or request tests. Prove lazy loading, eager loading, helper boot once, setup/body/teardown attribution, test environment and forced serial policy, exact seed/name forwarding, failure exits, unchanged application source, and explicit reload rejection. Optional local dependency absence may skip this suite in the core task, but the Rails CI task must fail on missing dependencies and the orchestrator must actually run it before claiming support.
- [x] **Version, docs and repeatable checks (Luna).** Own `version.rb`, README, CHANGELOG, Gemfile/optional Rails test bundle, CI, RBS, and packaging tests/config adjustments. Bump to 0.2.0; document plain Ruby and Rails commands and the child-only environment policy. Rails must not enter runtime gem dependencies. CI exercises core Ruby 3.3/3.4 and a real Rails matrix with an explicit required-integration flag. Keep lint active; do not add broad exclusions for new code.
- [x] **Review / verification / commits (orchestrator with Luna reviews).** Review actual changes and independent end-to-end evidence, run full core suites on checked Rubies, real Rails integration on a clean supported environment, lint, RBS, built-gem smoke, and whitespace checks. Resolve failures through owning Luna agents. Commit only verified changes with the workspace Lore trailers; do not push or publish.

## Verification commands and risks

Use explicit installed Ruby executables with matching `PATH`, clear inherited `GEM_HOME`/`GEM_PATH` for core checks, and use an isolated temporary gem home for Rails dependencies. Core verification is `ruby -S rake`; focused tests run with `ruby -Ilib:test test/test_NAME.rb` (one file per invocation). Rails verification sets `BRANCHPROOF_RAILS_INTEGRATION=1` and executes `test/test_rails_integration.rb` with the prepared bundle/environment. Run `rbs -I sig validate` and build/install the gem in a temporary directory for an installed CLI run.

The compile hook is a CRuby internal API. Real lazy/eager Rails loads and Bootsnap-disabled boot must exercise it before support is claimed. Test discovery must not run helper/fixture suites accidentally. Rails dependency/version availability is handled through isolated test installation and an explicit CI lane. Existing 122-test analytical/CLI suite remains the regression baseline. Each lane writes failing behavioral tests before production changes and reports exact commands and outputs.

## References

- [Rails testing guide](https://guides.rubyonrails.org/testing.html): test helper lifecycle and `PARALLEL_WORKERS=1` serial behavior.
- [Rails autoloading guide](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html): Zeitwerk lazy/eager loading and reloading configuration.
- [Bootsnap documentation](https://github.com/rails/bootsnap): `DISABLE_BOOTSNAP` and compilation-cache interaction.

## Verification completed — 2026-09-09

- CRuby 3.4.5, Rails 8.1.3.1, Zeitwerk 2.8.3, Minitest 5.27.0, Prism 1.9.0, Bootsnap 1.25.0: full default Rake task passed, 152 tests and 147,401 assertions, zero failures/errors/skips; RuboCop checked 57 files with zero offenses.
- CRuby 3.3.6, Minitest 5.25.5, Prism 1.4.0: 152 tests and 147,321 assertions, zero failures/errors; the four opt-in Rails integration tests skipped as intended.
- Real Rails acceptance: lazy/eager Zeitwerk loading, HTTP controller request, actual setup/body/teardown observation attribution, name/seed selection, standard unconditional Bootsnap setup under the disabled child policy, failure reporting, and reload rejection.
- Independent worker acceptance: a replaced compilation hook and source drift both produce exit 2, explicit diagnostics, and incomplete evidence. Failure reports retain project metadata.
- RBS validation and whitespace checks passed.
- Gem 0.2.0 built and installed through normal local RubyGems installation into an isolated gem home. Its installed CLI auto-detected both temporary Ruby and Rails projects, ran three tests in each, and produced complete analysis.
- Rails/Bootsnap remain optional integration dependencies; neither is a gem runtime dependency. Hosted CI is configured but was not executed in this session.

The original V1 implementation is retained in commits `ac85436` and `7d8c0dc`; this plan was initially committed as `97acc33`. The implementation lives on `implement-minitest-projects-v0.2`. No push or publication is included.
