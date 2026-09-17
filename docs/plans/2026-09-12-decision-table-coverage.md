# Decision table coverage

Derive the executable logical rules a supported Boolean decision expresses,
show which rules the existing test run exercises, and distinguish missing
evidence from rules that can be statically proven impossible. Decision Table
Coverage is a separate criterion: MC/DC asks whether each condition can
independently affect the outcome, decision-table coverage asks whether each
logical rule was exercised. Neither is inferred from the other.

## Scope

Boolean decisions Branchproof already represents with `AND`, `OR`, `NOT`, and
atoms, in `if`, `unless`, `elsif`, ternary, `while`, `until`, subjectless
`case`/`when`, and supported Boolean pattern guards. Multi-way `case`/`when`,
`case`/`in` alternatives, safe navigation, conditional assignment, exception
handling, and method invocation keep their alternative coverage model and
produce no Boolean table.

## Static derivation

Rules come from the short-circuit evaluation paths of the Boolean tree, not
from an exhaustive `2^n` expansion. A condition Ruby would skip becomes an
explicit `dont_care`, so `a && b` yields three rules, not four, and never
invents an evaluation Ruby would not perform.

Review resolution (2026-09-17): an exhaustive truth-table API is deferred until
there is a concrete consumer. It is not an intermediate step on the coverage path.

Path order is deterministic and structural: a conjunction lists its
short-circuiting false path first, a disjunction its true path first, and a
negation inverts the preference it inherits. Generation depends on the source
and schema version alone — never on runtime values, test order, the Minitest
seed, hash ordering, or observation counts.

Rule identity is the digest of the table schema version, the decision
identity, the normalized condition vector, and the expected outcome. `R1`-style
labels are display only.

## Runtime overlay

The overlay consumes the vectors the existing Branchproof run already
captured; the suite is never re-run per rule, per table, or per criterion. An
observation matches a rule when every non-don't-care rule position equals the
observed value and the decision outcome matches. Short-circuited conditions may
line up with don't-care positions and never satisfy a required true or false.
Covered rules keep their Minitest owners; uncovered rules report the condition
values they need and the expected decision, never the application inputs that
would produce them.

## Reachability

`observed`, `unknown`, `statically_impossible`. Prove impossibility or leave it
unknown: impossibility is never inferred from a missing test, a missing
observation, application conventions, framework validations, database
constraints, comments, or method names.

A small per-subject constraint model — lower and upper bounds with
inclusivity, a required equality, excluded equalities, a nil requirement, and a
truthiness requirement — decides contradictions for local, instance, class,
global, and constant subjects over numeric comparisons, equality against
immutable literals, `nil` checks, and bare truthiness. Ruby truthiness is not
Boolean equality: `if value` never becomes `value == true`. Method-call
subjects stay outside the model because a repeated call may return a different
value or have side effects. No SMT solver is required.

Review resolution (2026-09-17): the normalization model is not proof of Ruby
receiver types or value stability. Constraint analysis version 2 requires an
explicit safety fact from source analysis before applying a normalized constraint
to an exclusion. Arbitrary comparison receivers and mutation remain unknown;
literal truth values still prove impossibility. `--no-reachability` disables even
these exclusions and persists the mode. This narrower proof policy supersedes
the assumption that a matching variable name alone makes comparisons safe.

Impossible rules leave the coverage denominator but stay visible in the full
report. Runtime evidence is authoritative: an observation matching a rule the
model called impossible makes it `observed`, withdraws the claim, returns the
rule to the denominator, and emits a `constraint_model_conflict` diagnostic.

## Reporting

Per decision, a `DT` row in the coverage ladder, the reduced rule table with a
status per rule, owners for covered rules, condition-value requirements for
missing rules, and the reason code for impossible ones. In aggregate, rule
coverage and fully covered decisions stay distinct metrics. `--view
decision-tables` groups by table and honours `--missing-only`, which never
lists an impossible rule as a missing obligation.

JSON persists the table under `analysis.decisions[].decision_table` with its
schema and constraint-analysis versions. Saved-report validation checks the
enums, the rule-to-decision shape, evidence references, and the counters.
Comparison distinguishes rule coverage gained and lost from rule reachability
changed, and treats a changed rule set as changed decision-table context rather
than guessing a correspondence between old and new rules.

Review resolution (2026-09-17): version/mode changes must be disclosed, rule IDs
and evidence must validate, and the overall JSON regression Boolean must agree
with CLI failure for either MC/DC or decision-table loss. Uncalculated decisions
remain visible in missing-only output. Existing saved fields and CLI aliases are
retained for compatibility rather than removed as unused internal code.

## Limits

`max_conditions_for_decision_table` (default 12) and
`decision_table_rules_per_decision` (default 4096) bound the derivation. Beyond
either, the table reports `not_calculated` with an explicit reason instead of a
partial result.

## Non-goals

Full symbolic execution, SMT solving, domain-model or framework inference,
database schema reasoning, automatic test or input generation, cross-method
reasoning, condition merging from source text alone, and decision tables for
exception or invocation coverage.
