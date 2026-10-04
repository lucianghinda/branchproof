# Offline report collation

## Decisions

- User: “ok let's implement report collation using luna subagents”. Implement
  the proposed roadmap task on an isolated branch and deliver a reviewed PR.
- Combine observations and recompute analysis, minima, and gates. Percentages
  and previously calculated witnesses are never merged directly.
- Preserve serial execution boundaries. Collation reads saved artifacts and
  does not boot the application or add threaded/forked runner support.

## Command and collection completeness

```sh
branchproof collate unit.json integration.json --output combined.json
branchproof collate unit.json integration.json --manifest shards.json --output combined.json
branchproof report combined.json --format html --output coverage.html
```

Collate defaults to JSON. It accepts `--format terminal|json|github|html` and
`--output PATH`. Rendering an existing result uses the established report
command and its filters/minimum overrides. Collate itself does not introduce
configuration, source discovery, runner flags, or policy overrides.

The optional manifest is a JSON object with exactly a nonempty `shards` array:

```json
{"shards":[{"id":"unit","report":"unit.json"},{"id":"integration","report":"integration.json"}]}
```

Report paths in the manifest are relative to the manifest directory. Positional
inputs are the artifacts actually supplied; the manifest does not load omitted
artifacts implicitly. IDs and resolved paths must be unique. Undeclared inputs
are errors. Omitted declared inputs become missing shards, including when the
named file exists but was not supplied. An explicitly supplied unreadable input
is an IO error. Output must not overwrite an input or manifest, including inode
aliases; output replacement is atomic using the existing CLI writer.

Without a manifest, collection completeness is unknown. Recompute and display
the supplied evidence, but mark baseline INCOMPLETE/unfinalized, observation
completeness false, and return 2. A missing declared shard behaves similarly.
A complete manifest attests only that all declared artifacts were supplied;
it does not prove those shards selected every test in an application.

## Input compatibility

Accept current raw report schemas 1.4–1.6 after SavedReport validation. Require
matching schema, tool/criterion/runtime versions, current tool/runtime, complete
effective limits, Boolean reachability, requested level 1–3, project/framework
metadata, coverage-policy minima, and captured changed scope/changed minima.
Reject missing reconstruction metadata rather than guessing defaults. Raw
reports are accepted; nesting collated reports is outside this first contract.

Source inventories must match semantically, including relative paths, digests,
decisions, trees, support status, and diagnostics. Absolute checkout roots and
source-unit absolute paths may differ. Preserve existing test IDs and union
captured relative test locations so all owners remain renderable offline.
Test files, selectors, runner arguments, and seeds may differ; retain their
per-shard metadata rather than presenting the first shard as the whole run.

Canonical identical report duplicates are idempotent: sum their data once.
Conflicting or partial run-ID overlap is an error. One artifact cannot satisfy
two distinct expected shard IDs. Repeated test IDs across distinct runs are
allowed if identity fields match. Sum phase counts and preserve the worst
test status (failed, unknown, skipped, passed); failure is never overwritten
by a later success. Baseline counts count executions, summed across unique
input artifacts, rather than the number of distinct evidence owners.

## Reanalysis and failure preservation

Reconstruct inventory from persisted records, recursively symbolize keys for
Analyzer, and merge Evidence snapshots with the captured limits. Use a real
input run ID to seed Evidence; do not invent an extra contributor. Recompute
Analyzer and Minimizer results under the captured level/settings. Carry equal
whole-run and changed-scope thresholds into fresh Report evaluation.

Input false completeness bits remain false even if recomputation could produce
a complete-looking result. Missing collection information makes observation
completeness false. Aggregate ERROR has highest precedence, followed by
INCOMPLETE/unfinalized, then FAILED, then PASSED. A failed shard never becomes
successful. Error/failed input baselines do not receive invented successful
analysis; partial collections of otherwise successful runs can still show
informational coverage. Existing gate/exit conventions apply: unavailable or
incomplete is 2, failed tests or available failed gates is 1, complete passing
analysis is 0. Storage limits exceeded by the union reject the collation with
exit 2 and leave output untouched; analysis search limits yield an incomplete
report. Preserve input diagnostics and add actionable collation diagnostics.

## Saved output and provenance

Only collated outputs use schema 1.7; normal analyze writers stay on 1.4–1.6.
A required `collation` record has version `1.0`, collection_status
(`complete`, `incomplete`, or `unknown`), expected_shards (IDs or null),
missing_shards, and a nonempty shards array. Each unique shard records its ID,
input paths, canonical report digest, run IDs, original baseline, completeness,
and run metadata. Run IDs and baseline counters must agree with provenance.
The validator enforces collection status, missing IDs, uniqueness, and the
inability of incomplete inputs/collections to claim passing completeness.
Schema 1.7 permits optional matching changed scope/policy and retains their
existing strict recalculation checks. Offline policy overrides must not
downgrade schema 1.7. Comparison accepts validated collated reports and retains
its existing complete-run requirements.

Terminal views, GitHub output, and HTML disclose collection status, supplied
and expected counts, missing IDs, and contributor labels. JSON retains complete
provenance. Reuse existing escaping in each renderer.

## Verification

Prove two real serial CLI selections combine into the same analysis/ownership
as their equivalent full run, including a witness available only across shards.
Delete application files before collation to establish offline behavior. Cover
Minitest and RSpec consumers, duplicate inputs, reordered inputs, repeated
tests, failed/skipped/incomplete/missing shards, policy recalculation, changed
scope, source/settings/runtime mismatches, aggregate limits, metadata tampering,
input/output aliases, atomic output, and saved report/HTML/compare round trips.
No dependencies or gem version bump are required.
