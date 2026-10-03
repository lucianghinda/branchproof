# Changed-decision gates and evidence explanations

## Approved outcome

Developers can enforce coverage on decisions changed since a Git commit and see
which Boolean evidence is missing. Explanations use source expressions and
captured analysis, without an LLM or inferred domain terminology.

`branchproof analyze --changed-since REF --minimum-changed mcdc=80` evaluates the
captured changed decisions independently of any whole-run `--minimum` gates.
`branchproof report SNAPSHOT --minimum-changed mcdc=80` uses captured scope and
evidence offline. Configuration accepts `minimum_changed` with the same five
criteria and numeric validation as `minimum`. CLI overrides merge by criterion.
An analyze invocation with changed minima but no changed-since ref fails before
executing tests. Offline use requires a captured scope. Compare and doctor do
not accept the option. Doctor can still inspect configuration containing it.

## Gate contract

Use exact integer counts and rational comparisons, never rounded percentages.
Display filters do not affect gate denominators. Existing whole-run gates remain
independent. Failed tests remain failures; unavailable or incomplete evidence
cannot pass either a gate or an empty-scope exemption. A valid empty changed scope
is explicitly `not_applicable` (no percentage), allowing success when the rest of
the run is valid. Unsupported-only scope or a zero denominator for a requested
criterion is unavailable. Exit codes remain 0 success, 1 failure, 2 unavailable.

Preserve schema 1.4 for ordinary reports and 1.5 for informational changed scope.
Reports containing a changed policy use schema 1.6 with `changed_coverage_policy`.
Saved-report validation recomputes policies from captured evidence; a new offline
override upgrades a 1.5 document to 1.6. Retain backward compatibility for older
reports. Terminal, GitHub and HTML display independent changed gate results and
scope; JSON retains full evidence.

## Evidence wording

For `user.paid? && !user.suspended?`, a missing pair may explain:

```text
Missing evidence for: !user.suspended?
Find two executions where:
  user.paid? remains true
  !user.suspended? changes between true and false
  the decision outcome changes
Observed:
  user.paid? = true
  !user.suspended? = true
  decision = true
Missing counterpart:
  user.paid? = true
  !user.suspended? = false
  decision = false
```

Derive this from existing analyzer candidates, retaining masking and
short-circuit semantics. The inventory represents unary negation in the Boolean
tree: this example's atomic expression is `user.suspended?`, so the actual output
must report its observed `false` and candidate `true`, while showing the complete
decision expression with `!`. Do not relabel atomic values as negated values.
Do not describe an unobserved vector as observed, a
skipped condition as an observed Boolean, or a hypothetical combination as a
feasible application state. When exact constraints cannot support that template,
use faithful expression-based candidate wording or explain why evidence is
unavailable. Do not generate application objects, test code, or domain sentences
such as “suspension denies access.” Keep rendering escaped in HTML and GitHub.

## Boundaries

No test selection, merge-base inference, instrumentation changes, new dependency,
gem version bump, or AI integration. Existing changed-scope semantics remain.
