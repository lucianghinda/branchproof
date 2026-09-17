# Module Branchproof::DecisionTable <a id="module-Branchproof-DecisionTable"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/decision_table.rb |

Derives the executable logical rules of a supported Boolean decision and
overlays the runtime evidence that the existing Branchproof run captured.

Rules come from the Boolean tree itself rather than from an exhaustive
Cartesian expansion, so Ruby's short-circuit semantics are preserved: a
condition the interpreter would skip becomes an explicit `dont_care` value
instead of two separate rules.

Nothing here executes application code, and no additional test run is
required: overlay consumes the vectors already recorded for the decision.

## Constants
### `CONDITION_VALUES` <a id="constant-CONDITION_VALUES"></a> <a id="CONDITION_VALUES-constant"></a>
Not documented.

### `CONSTRAINT_ANALYSIS_VERSION` <a id="constant-CONSTRAINT_ANALYSIS_VERSION"></a> <a id="CONSTRAINT_ANALYSIS_VERSION-constant"></a>
Not documented.

### `COVERAGE_STATUSES` <a id="constant-COVERAGE_STATUSES"></a> <a id="COVERAGE_STATUSES-constant"></a>
Not documented.

### `COVERAGE_SUMMARY_STATUSES` <a id="constant-COVERAGE_SUMMARY_STATUSES"></a> <a id="COVERAGE_SUMMARY_STATUSES-constant"></a>
Not documented.

### `DEFAULT_MAX_CONDITIONS` <a id="constant-DEFAULT_MAX_CONDITIONS"></a> <a id="DEFAULT_MAX_CONDITIONS-constant"></a>
Not documented.

### `DEFAULT_MAX_RULES` <a id="constant-DEFAULT_MAX_RULES"></a> <a id="DEFAULT_MAX_RULES-constant"></a>
Not documented.

### `DONT_CARE` <a id="constant-DONT_CARE"></a> <a id="DONT_CARE-constant"></a>
Not documented.

### `FALSE_VALUE` <a id="constant-FALSE_VALUE"></a> <a id="FALSE_VALUE-constant"></a>
Not documented.

### `NOT_CALCULATED_REASONS` <a id="constant-NOT_CALCULATED_REASONS"></a> <a id="NOT_CALCULATED_REASONS-constant"></a>
Not documented.

### `REACHABILITY_STATUSES` <a id="constant-REACHABILITY_STATUSES"></a> <a id="REACHABILITY_STATUSES-constant"></a>
Not documented.

### `SCHEMA_VERSION` <a id="constant-SCHEMA_VERSION"></a> <a id="SCHEMA_VERSION-constant"></a>
Not documented.

### `TABLE_STATUSES` <a id="constant-TABLE_STATUSES"></a> <a id="TABLE_STATUSES-constant"></a>
Not documented.

### `TRUE_VALUE` <a id="constant-TRUE_VALUE"></a> <a id="TRUE_VALUE-constant"></a>
Not documented.

### `VALUE_LABELS` <a id="constant-VALUE_LABELS"></a> <a id="VALUE_LABELS-constant"></a>
Not documented.

## Public Class Methods
### `build(decision:, vectors: = [], limits: = {}, reachability: = true)` <a id="method-c-build"></a> <a id="build-class_method"></a>
Builds the reduced, runtime-overlaid table for one Boolean decision.
- **@raise** [ArgumentError]

### `classify_vectors(rules, vectors)` <a id="method-c-classify_vectors"></a> <a id="classify_vectors-class_method"></a>
Generated traces have nil in every skipped condition position. Their
normalized vector is therefore an exact table key and can be classified
without scanning every rule. Malformed or hand-built observations retain the
historical matcher as a bounded compatibility fallback.

### `combine(node, type, budget)` <a id="method-c-combine"></a> <a id="combine-class_method"></a>
Not documented.

### `coverage_entry(table)` <a id="method-c-coverage_entry"></a> <a id="coverage_entry-class_method"></a>
The per-decision row the coverage ladder renders.

### `coverage_status(covered, required, generated)` <a id="method-c-coverage_status"></a> <a id="coverage_status-class_method"></a>
Not documented.

### `enumerate(node, prefer, budget)` <a id="method-c-enumerate"></a> <a id="enumerate-class_method"></a>
Enumerates every short-circuit evaluation path of the Boolean tree.

`prefer` orders the paths deterministically: a conjunction lists its
short-circuiting false path first, a disjunction its true path first, and a
negation inverts the preference it inherits. Returns nil once the path count
would exceed `budget`.

### `fast_match_positions(vector, by_signature, condition_count)` <a id="method-c-fast_match_positions"></a> <a id="fast_match_positions-class_method"></a>
Not documented.

### `fetch(record, key)` <a id="method-c-fetch"></a> <a id="fetch-class_method"></a>
Not documented.

### `generic_matches(rules, vectors)` <a id="method-c-generic_matches"></a> <a id="generic_matches-class_method"></a>
Not documented.

### `limit(limits, key, fallback)` <a id="method-c-limit"></a> <a id="limit-class_method"></a>
Not documented.

### `matches?(rule, vector)` <a id="method-c-matches-3F"></a> <a id="matches?-class_method"></a>
A runtime observation matches a rule when every required condition value
matches and the decision outcome matches. Conditions Ruby skipped may only
line up with don't-care positions.
- **@return** [Boolean]

### `not_calculated(decision_id, reason)` <a id="method-c-not_calculated"></a> <a id="not_calculated-class_method"></a>
Not documented.

### `overlay(decision_id:, rules:, vectors:, reachability: = true, indexed: = false)` <a id="method-c-overlay"></a> <a id="overlay-class_method"></a>
Not documented.

### `overlay_rule(decision_id, rule, vectors, diagnostics)` <a id="method-c-overlay_rule"></a> <a id="overlay_rule-class_method"></a>
Public compatibility wrapper: callers historically passed all vectors, so
retain matcher filtering for direct calls.

### `overlay_rule_matches(decision_id, rule, matched, diagnostics)` <a id="method-c-overlay_rule_matches"></a> <a id="overlay_rule_matches-class_method"></a>
Not documented.

### `percentage(covered, required)` <a id="method-c-percentage"></a> <a id="percentage-class_method"></a>
Not documented.

### `representable?(node, condition_count)` <a id="method-c-representable-3F"></a> <a id="representable?-class_method"></a>
Only AND, OR, NOT, and atoms within the decision's own condition range are
representable; anything else leaves the table uncalculated rather than
producing a table that does not describe the decision.
- **@return** [Boolean]

### `rule(decision_id, conditions, path, index, reachability: = true, prepared_constraints: = nil)` <a id="method-c-rule"></a> <a id="rule-class_method"></a>
rubocop:disable-next Metrics/ParameterLists

### `rule_id(decision_id, values, outcome)` <a id="method-c-rule_id"></a> <a id="rule_id-class_method"></a>
Rule identity depends only on the decision, the normalized condition vector,
the expected outcome, and the table schema version. It never depends on a test
name, a runtime observation, or the Minitest seed.

### `signature(values, outcome)` <a id="method-c-signature"></a> <a id="signature-class_method"></a>
Not documented.

### `static_reachability(conditions, values, prepared_constraints: = nil)` <a id="method-c-static_reachability"></a> <a id="static_reachability-class_method"></a>
Conservative static reachability: prove impossibility, or answer unknown.

### `summary(decision_id:, rules:, diagnostics:, reachability_analyzed: = true)` <a id="method-c-summary"></a> <a id="summary-class_method"></a>
Not documented.

### `unavailable_reason(decision, limits)` <a id="method-c-unavailable_reason"></a> <a id="unavailable_reason-class_method"></a>
Names why a decision carries no Boolean table, or nil when it carries one.

### `unique_atom_indices?(node, seen = {})` <a id="method-c-unique_atom_indices-3F"></a> <a id="unique_atom_indices?-class_method"></a>
- **@return** [Boolean]

### `unsupported_coverage_entry()` <a id="method-c-unsupported_coverage_entry"></a> <a id="unsupported_coverage_entry-class_method"></a>
Not documented.
