# Readable terminal report plan

Goal: make the default terminal report useful to a person reading test
evidence, while preserving full identifiers, schema, analysis, and exit
behavior in JSON. Luna implements; root reviews and verifies.

## Presentation contract

- Lead with tool version, test outcome/counts, proven/eligible conditions and
  percentage, analysis completeness, decision scope counts, and observation
  counts. Separate summary, decisions, and supporting sets with whitespace.
- Keep failed/skipped tests, unsupported/unexecuted decisions, aborted or
  unattributed observations, diagnostics, and partial/lower-bound status
  visible. Do not print a computed coverage percentage when analysis was not
  requested or is unavailable. Keep zero eligible scope N/A.
- Show source path, line, predicate, and a short decision identifier together.
  Use condition index/expression instead of repeating condition hashes.
- Show vectors with short identifiers, truth values, outcomes, and readable
  `ClassName#test_method` owners. Explain `T`, `F`, and short-circuited `-` once.
- Resolve names from evidence tests, with baseline tests as fallback. Missing
  metadata falls back to the short test ID. Disambiguate duplicate display
  names with source location or short ID.
- Shorten IDs consistently everywhere in terminal output: decisions, vectors,
  witness pairs, supporting-set scope and members, and unknown test owners.
  Start at eight characters and extend colliding prefixes until distinct.
  Preserve already-short identifiers and input data; never truncate JSON IDs.
- Present each condition's status once, with witness vector references or
  missing counterpart constraints where relevant. Raw bit masks can remain
  in JSON; terminal witness pairs must still explain the evidence.
- Render supporting vector/test sets with readable labels and their exact
  or partial result status. Deduplicate identical terminal rows without
  changing JSON minima. Preserve the note that other tests can still matter.
- Preserve the existing levels, output options, dependencies, and CLI scope.

## Execution

- [x] Add report regressions for names/fallbacks, duplicate names, colliding
  prefixes, vectors/witnesses/minima, unavailable/partial analysis, and JSON
  identity preservation (including rendering terminal before JSON).
- [x] Update terminal rendering in `lib/branchproof/report.rb`; keep JSON,
  metric calculation, and exit-code logic unchanged. A small dedicated
  terminal formatter is acceptable only if it avoids inflating `Report`.
- [x] Verify existing report and CLI acceptance tests; update only assertions
  that intentionally describe the previous presentation.
- [x] Root reviews an actual terminal run and a representative external
  report to check readability and retained diagnostics/evidence.
- [x] Update README examples and changelog after the output is finalized.
- [x] Run the full Rails-enabled suite, lint, RBS, and focused Ruby 3.3 checks.
- [x] Rebuild the candidate and checksum; verify the installed command emits
  names/short IDs, and JSON retains full stable IDs.
- [x] Commit with Lore records.

Reversible presentation changes only: do not modify test execution,
instrumentation, source inventory, minimization, or supported-syntax rules.
