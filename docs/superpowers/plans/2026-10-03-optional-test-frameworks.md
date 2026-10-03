# Optional Test Frameworks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-ruby:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Let RSpec and offline-report consumers install Branchproof without Minitest.

**Architecture:** Keep lazy adapter selection and move the existing Minitest
support range into selected-adapter validation. Verify the runtime dependency
change with actual packaged consumers isolated from the development bundle.

**Tech Stack:** Ruby 4, RubyGems/Bundler, Minitest, RSpec; no new dependencies.

## Task 1: Selected Minitest loading and support diagnostics

Files: `lib/branchproof/worker.rb`, `lib/branchproof/minitest_adapter.rb`,
`test/test_worker.rb`, `test/test_minitest_adapter.rb` and `sig/branchproof.rbs`
as needed for the chosen shared public loader.

- [x] Add failing tests for missing Minitest, unrelated transitive LoadError,
  too-old/6.x versions, supported lower bound and current version. Assert missing
  diagnostic code `minitest_missing`, unsupported code
  `minitest_unsupported_version`, range/version and bundle guidance in messages.
- [x] Run `bundle exec ruby -Itest test/test_worker.rb` and adapter tests to
  observe failures caused by missing diagnostics/version validation.
- [x] Implement narrow framework loading and `Gem::Requirement.new(">= 5.25.5",
  "< 6")` validation before application boot and lifecycle hooks. Follow existing
  ArgumentError diagnostics, preserve unrelated LoadError, and keep RSpec lazy.
- [x] Run worker/adapter regression tests and RuboCop on touched Ruby files.
- [x] Independent Luna specification review, then quality review; resolve findings.
- [x] Parent commits reviewed code with Lore trailers.

## Task 2: Optional dependency and isolated packaged consumers

Files: `branchproof.gemspec`, `Gemfile.lock`, `test/test_packaging.rb`, new
`test/test_optional_frameworks.rb` and a small test support helper if justified,
`README.md`, `CHANGELOG.md`. Keep `Gemfile`'s Minitest development entry.

- [x] Add a failing assertion that runtime dependency names exclude Minitest.
- [x] Add actual built-gem consumer tests for RSpec-only, Minitest-only and
  neither-framework environments. Explicitly assert absent framework specs and
  constants, valid analysis/test attribution, report/compare operation and
  structured missing-adapter exit 2. Clear inherited Bundler and Ruby load paths.
- [x] Run `bundle exec ruby -Itest test/test_optional_frameworks.rb` and packaging
  tests; confirm the old gemspec prevents the RSpec-only/no-framework install.
- [x] Remove only the Minitest runtime dependency, refresh the local lockfile
  without upgrading unrelated packages, and keep current support boundaries.
- [x] Update installation/support docs with app-owned framework bundle examples;
  add an unreleased changelog entry. No doctor or Minitest 6 support claim.
- [x] Run targeted consumer/packaging tests and lint. Independent Luna spec then
  quality review; resolve findings and parent commits the reviewed slice.

## Task 3: Integrated verification and delivery

- [x] Run `bundle exec rake` for the full suite and lint; validate RBS and inspect
  packaged metadata. Run `bundle exec rake docs` and inspect generated changes.
- [x] Fresh Luna integrated review of dependency selection, errors, offline paths
  and consumer isolation; resolve significant findings and rerun affected checks.
- [x] Record verification and reconcile the workspace roadmap's delivered slices.

Delivery after local verification: push `codex/optional-test-frameworks`, open a
PR, check all five repository CI lanes and fix failures. Keep the worktree for
review. Utility scripts use Ruby's standard library and are removed afterward.

Run Ruby tools with `/Users/luciang/.rubies/ruby-4.0.1/bin` prepended to PATH and
set `RUBOCOP_CACHE_ROOT=/private/tmp/branchproof-rubocop-cache` for lint.

## Verification (2026-10-03)

- Full local `bundle exec rake`: 1,817 tests, 243,417 assertions, no failures or
  errors, 13 optional-integration skips; RuboCop checked 201 files without offenses.
- After the final metadata consistency fix: worker 24/85, Minitest adapter 5/20,
  isolated packaged consumers 1/58, and targeted lint passed. Evidence tests pass
  25/77; packaging passes 7/97. CI will rerun the complete final tree.
- RBS validation passed with a temporary `Rake::TaskLib` signature stub because
  Rake signatures are not installed locally. This validates signatures, not
  implementation types. `bundle exec rake docs` regenerated the checked-in docs.
- The previous runtime dependency was temporarily restored in a built archive:
  dependency-enabled installs correctly failed in RSpec-only and framework-free
  roots. The final harness passes without that dependency. A temporary synthetic
  test was removed after it exposed RubyGems' cached mutable gemspec behavior.
- Independent Luna spec and quality reviews approved the implementation after
  fixing incomplete analysis propagation through Evidence merges and aligning
  report metadata with the activated Minitest package version.
- Workspace roadmap Tasks 7/8 reflect their merged PRs; Task 9's dependency slice
  is implemented. Doctor, Minitest 6, SimpleCov and collation remain separate.
