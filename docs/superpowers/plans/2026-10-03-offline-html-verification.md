# Offline HTML report verification

Implementation adds the HtmlReport renderer, saved-report CLI format, signatures,
acceptance tests, README/changelog guidance and generated API documentation.
It reuses CoverageIndex, SummaryRanking and Report policy/scenario presentation;
there are no dependency, version, saved-schema or coverage-calculation changes.

## Automated checks

- Full `bundle exec rake`: 1,801 tests, 243,280 assertions, zero failures/errors,
  13 optional integration skips. RuboCop: 200 files, no offenses.
- RBS syntax and signature validation pass. Validation used an external empty
  Rake::TaskLib declaration because the installed RBS environment lacks Rake
  signatures; this is signature validation, not implementation type checking.
- Built gem was extracted into a separate directory. Both its public Report API
  and executable rendered HTML from a source-free saved snapshot.
- Saved-report acceptance checks stdout/file output, mcdc alias parity, deleted
  source files, unchanged run marker, input/symlink/hardlink collision protection,
  failed/incomplete/analysis-free reports and option restrictions.
- Changed-scope acceptance proves scope coverage of 100% does not override the
  whole-run 50% coverage or its failed minimum gate.
- API documentation regenerated successfully; diff whitespace check passes.

## Browser checks

A real CLI-generated snapshot contains covered and missing MC/DC, alternatives,
an excluded impossible rule, long expressions and a hostile script-like literal.
The fixture source project was removed before HTML rendering.

- Opened the generated file directly with browser offline mode enabled.
- Checked desktop at 1440px and mobile at 390px; page width stays at viewport
  width, while wide tables scroll within focusable regions.
- Keyboard Enter opens native test disclosures; ArrowRight scrolls evidence.
- File navigation reaches generated decision anchors; no broken local targets.
- Browser reports zero scripts and zero external resource requests.
- Desktop axe audit: zero violations and zero incomplete checks. Mobile offscreen
  table cells can require manual contrast inspection; visible text was inspected.
- Visual verdict: 94/pass against the written design, after fixing readable test
  labels, unique region names, keyboard table access and long-token wrapping.
  No image reference was supplied; this is not a pixel-fidelity comparison.

## Review and limits

Luna implementers completed the renderer and CLI slices. Separate Luna reviewers
approved each slice for specification and quality, followed by a fresh integrated
review. Findings about reachability detail and run-wide unsupported totals were
fixed and re-reviewed.

HTML is intentionally available only through offline `report`. Explicit `--view`
is rejected; the integrated layout supports levels and display filters. Browser
verification used Chromium; no manual screen-reader or cross-browser session was
performed. Optional Rails/RSpec matrix coverage is delegated to repository CI.
