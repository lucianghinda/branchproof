# Actionable missing coverage

Make the location and missing Boolean scenario visible for every unproven
condition. Keep source expressions in the explanation; do not infer application
inputs or claim a reachable path from Boolean evidence alone.

- Correct candidate generation for missing false outcomes, with regressions
  for partially observed AND and OR decisions.
- Add `--missing-only` for terminal reports at levels 2 and 3. Preserve the
  full summary and diagnostics, hide proven conditions and supporting sets,
  and show required truth values alongside relevant existing observations.
- Keep JSON complete; reject the terminal filter with JSON or level 1.
- Distinguish unavailable analysis from a complete report with no gaps.
- Verify analyzer, renderer, and CLI regressions, then run tests, lint, RBS,
  documentation generation, and the release build gate.

The existing full terminal report remains available without the option.
No version bump, history rewrite, or publishing is part of this change.
