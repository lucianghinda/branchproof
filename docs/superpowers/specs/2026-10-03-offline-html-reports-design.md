# Offline HTML reports

Approved scope: turn a saved Branchproof snapshot into a portable report with
`branchproof report snapshot.json --format html --output coverage.html`.

## Behavior

The output is one HTML document with inline CSS, no JavaScript, external assets,
source reads, or network requests. It also works on stdout. Existing saved report
validation, collision protection, coverage policy, and exit codes remain intact.
Live analyze and compare do not accept HTML in this increment.

The page presents baseline/completeness, whole-run coverage and policy, captured
changed scope, ranked file navigation, decision details, missing scenarios, and
contributing tests. CoverageIndex supplies evidence and SummaryRanking supplies
ordering. Report supplies existing coverage/policy/scenario wording. Unknown,
not-calculated, excluded, unsupported, and incomplete states stay explicit.
Failed or incomplete counts are labeled lower bounds. An empty selection is never
advertised as proof of full coverage.

Focus intersects captured changed scope. Top limits ranked displayed decisions
before grouping into files and reports the hidden count; it never changes coverage
denominators. Missing-only hides decisions without known gaps. Level 1 shows the
overview and decision summaries; level 2 adds scenarios and coverage detail; level
3 adds contributing test evidence. Explicit --view is rejected because HTML has
one integrated layout. Without analysis, inventory remains visible with unavailable
analysis clearly stated and without invented gaps.

## Layout and accessibility

Use a restrained technical report: warm off-white page, dark ink, teal navigation,
amber missing-evidence accents, thin rules, monospace expressions, local serif
headings, and local sans-serif body fonts. No decorative dashboard or animation.
At desktop widths use a compact file navigation column next to decision sections;
stack navigation above content on narrow screens. Tables scroll locally, long
expressions wrap, focus rings are visible. Use semantic headings, landmarks,
table headers, skip link, and native links/details with keyboard access. Status
text carries meaning independently of color. Print styling preserves evidence.

All snapshot strings are untrusted text. Escape every text/attribute value through
one standard-library HTML escape helper. Build internal anchors from generated
ordinals rather than user-controlled paths/IDs. Do not generate external/source
URLs. Inline styles are static; no snapshot content enters CSS or executable code.

## Verification

Tests cover navigation target integrity, hostile expressions/paths/test names and
diagnostics, missing/excluded rules and denominators, test attribution, selectors,
analysis unavailable, incomplete runs, and changed/global policy distinction.
CLI acceptance generates a valid snapshot, removes source checkout, then renders
HTML; tests stdout/output files, option rejections, collision safety, and exit codes.
Browser inspection checks desktop/mobile, keyboard navigation, native disclosure,
offline operation and hostile text. Visual verdict uses this written design as
the reference (no image reference was supplied) and records that limitation.

## Decisions

- Offline report only: keeps collection and report delivery independently scoped.
- Reuse computed evidence: no additional coverage engine or dependency.
- Integrated layout: reject --view rather than silently ignoring user intent.
- Top applies to decisions globally: every file link leads to visible detail.
- Native HTML/CSS: portable CI artifact with no runtime or script dependency.
