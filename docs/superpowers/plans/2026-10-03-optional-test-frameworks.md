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

- [ ] Add failing tests for missing Minitest, unrelated transitive LoadError,
  too-old/6.x versions, supported lower bound and current version. Assert missing
  diagnostic code `minitest_missing`, unsupported code
  `minitest_unsupported_version`, range/version and bundle guidance in messages.
- [ ] Run `bundle exec ruby -Itest test/test_worker.rb` and adapter tests to
  observe failures caused by missing diagnostics/version validation.
- [ ] Implement narrow framework loading and `Gem::Requirement.new(">= 5.25.5",
  "< 6")` validation before application boot and lifecycle hooks. Follow existing
  ArgumentError diagnostics, preserve unrelated LoadError, and keep RSpec lazy.
- [ ] Run worker/adapter regression tests and RuboCop on touched Ruby files.
- [ ] Independent Luna specification review, then quality review; resolve findings.
- [ ] Parent commits reviewed code with Lore trailers.

## Task 2: Optional dependency and isolated packaged consumers

Files: `branchproof.gemspec`, `Gemfile.lock`, `test/test_packaging.rb`, new
`test/test_optional_frameworks.rb` and a small test support helper if justified,
`README.md`, `CHANGELOG.md`. Keep `Gemfile`'s Minitest development entry.

- [ ] Add a failing assertion that runtime dependency names exclude Minitest.
- [ ] Add actual built-gem consumer tests for RSpec-only, Minitest-only and
  neither-framework environments. Explicitly assert absent framework specs and
  constants, valid analysis/test attribution, report/compare operation and
  structured missing-adapter exit 2. Clear inherited Bundler and Ruby load paths.
- [ ] Run `bundle exec ruby -Itest test/test_optional_frameworks.rb` and packaging
  tests; confirm the old gemspec prevents the RSpec-only/no-framework install.
- [ ] Remove only the Minitest runtime dependency, refresh the local lockfile
  without upgrading unrelated packages, and keep current support boundaries.
- [ ] Update installation/support docs with app-owned framework bundle examples;
  add an unreleased changelog entry. No doctor or Minitest 6 support claim.
- [ ] Run targeted consumer/packaging tests and lint. Independent Luna spec then
  quality review; resolve findings and parent commits the reviewed slice.

## Task 3: Integrated verification and delivery

- [ ] Run `bundle exec rake` for the full suite and lint; validate RBS and inspect
  packaged metadata. Run `bundle exec rake docs` and inspect generated changes.
- [ ] Fresh Luna integrated review of dependency selection, errors, offline paths
  and consumer isolation; resolve significant findings and rerun affected checks.
- [ ] Record verification and reconcile the workspace roadmap's delivered slices.

Delivery after local verification: push `codex/optional-test-frameworks`, open a
PR, check all five repository CI lanes and fix failures. Keep the worktree for
review. Utility scripts use Ruby's standard library and are removed afterward.

Run Ruby tools with `/Users/luciang/.rubies/ruby-4.0.1/bin` prepended to PATH and
set `RUBOCOP_CACHE_ROOT=/private/tmp/branchproof-rubocop-cache` for lint.
