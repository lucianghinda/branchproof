# Report collation implementation plan

> **For agentic workers:** Use superpowers-ruby:subagent-driven-development with Luna implementers and independent spec then quality reviews. One implementation writer at a time. Parent owns documentation, commits, and delivery.

**Goal:** Recompute trustworthy combined coverage from compatible serial reports.

**Architecture:** Collation validates persisted input contracts, merges existing
Evidence, and reruns Analyzer/Minimizer/Report. A versioned provenance validator
protects schema 1.7. CLI resolves an optional expected-shard manifest and reuses
the atomic output writer; all renderers disclose collection completeness.

**Tech Stack:** Ruby 4, standard library, existing Branchproof analysis classes.

## Task 1: Offline core and saved contract

Files: new `lib/branchproof/collation.rb`, optional focused
`lib/branchproof/collation_metadata.rb`, `test/test_collation.rb`; extend
`lib/branchproof.rb`, `lib/branchproof/saved_report.rb`,
`lib/branchproof/comparison.rb`, `lib/branchproof/report.rb` (schema preservation
only), `sig/branchproof.rbs`, and saved-report/comparison tests.

- [ ] Write a RED core test using serialized real Report documents:

  ```ruby
  result = Branchproof::Collation.new(
    inputs: [{id: "left", path: "left.json", document: left},
             {id: "right", path: "right.json", document: right}],
    expected_shards: %w[left right]
  ).call
  assert_equal "1.7", result.fetch("schema_version")
  assert_equal "complete", result.dig("collation", "collection_status")
  assert_equal "PASSED", result.dig("baseline", "status")
  Branchproof::SavedReport.new(result).validate!
  ```

- [ ] Implement the constructor above; `.call` returns a validated string-key
  JSON-compatible document. Each input wrapper has symbol keys. Optional IDs
  default to a canonical report digest when no manifest exists. Normalize and
  copy input documents; never mutate originals. Match the design compatibility
  fields explicitly and use real input run IDs when constructing Evidence.
- [ ] Test and implement exact duplicate idempotency, overlap rejection,
  repeated-test phase sums/failure precedence, and summed baseline executions.
  Compare reversed input order after normalizing presentation timestamps.
- [ ] Rerun analysis/minimization using symbolized persisted inventory and
  captured limits/reachability/level. Carry identical thresholds and changed
  scope into Report. Preserve every false input completeness bit. Cover a
  witness only available across runs, failed/incomplete collections, and both
  aggregate storage limits and analysis search limits.
- [ ] Emit and validate schema 1.7 provenance with contributor input paths,
  canonical digest, run IDs, baseline, completeness, and original run metadata.
  Keep normal writers unchanged, permit optional strict changed scope/policy,
  preserve schema during offline overrides, and enable existing Comparison.
- [ ] Run focused tests, RBS as appropriate, and lint; obtain spec then quality
  review before starting the next implementation writer.

## Task 2: Manifest, CLI, views, and real consumers

Files: new `lib/branchproof/collation_manifest.rb`, manifest unit tests, and
`test/test_collation_acceptance.rb`; extend `lib/branchproof/cli.rb`, Report and
terminal/GitHub/HTML coordinators, `lib/branchproof.rb`, signatures, and their
focused tests.

- [ ] Add RED command tests for `collate REPORT... [--manifest PATH]
  [--format terminal|json|github|html] [--output PATH]`, default JSON. Reject
  unknown/missing arguments and require at least one supplied report.
- [ ] Resolve manifest report paths relative to its directory; validate exact
  shape, nonempty IDs/paths, duplicate IDs/paths, undeclared inputs, missing
  declared artifacts, aliases, and artifact reuse across declared IDs.
- [ ] Protect all inputs plus manifest from output collisions before writing;
  use existing `output_report` atomic replacement. Read only supplied reports
  and pass wrappers/expected IDs to Collation. Preserve code 2 for malformed,
  incompatible, unknown, or incomplete collections.
- [ ] Add shared collation summary lines and reuse them in each renderer with
  its existing escaping, including focused/summary views and GitHub summaries.
- [ ] Generate actual Minitest and RSpec shard reports from serial selections,
  collate them, and compare normalized coverage/ownership with a full run.
  Delete project sources/tests before collating. Test cross-shard MC/DC,
  filtering, repeated tests, failure/missing inputs, JSON/HTML saved roundtrip,
  comparison, policy overrides, output collision and preservation on failure.
- [ ] Run focused CLI/rendering/acceptance checks and lint; resolve independent
  spec then quality reviews.

## Task 3: Documentation and delivery

- [ ] Document command, manifest example, default incomplete behavior, duplicate
  and repeated-test counting, compatibility requirements, schema 1.7 reader
  requirements, and serial-only scope in README/CHANGELOG. Regenerate docs.
- [ ] Run full `bundle exec rake`, RBS validation with temporary Rake signature
  stub, packaging, and diff checks. Obtain a fresh integrated review.
- [ ] Deliver a Lore commit and new PR; verify all eight CI jobs and record
  final evidence in the PR and workspace roadmap.

Commands use `env PATH=/Users/luciang/.rubies/ruby-4.0.1/bin:$PATH bundle exec`.
RuboCop cache: `/private/tmp/branchproof-rubocop-cache`. Utility scripts are Ruby
standard library under `/private/tmp`, removed on completion.

Baseline at `65a87dd`: Evidence 25 runs/77 assertions and SavedReport 21/84,
zero failures/errors/skips. The preceding PR's full suite and eight CI jobs
passed. Reconstruction research proved persisted inventory + observations are
sufficient for reanalysis without source files; inventory keys must be
recursively symbolized for analyzer graph traversal.
