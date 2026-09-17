# Module Branchproof::Constraints <a id="module-Branchproof-Constraints"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/constraints.rb |

Normalizes simple atomic conditions into subject/operator/value records and
decides, conservatively, whether a set of required condition truths can hold
at the same time.

The module never evaluates application code. It only inspects the syntax of a
condition, and it answers "contradictory" only when the contradiction follows
from the normalized constraints alone. Every other shape stays unrepresented,
which leaves the owning decision-table rule reachability `unknown`.

## Constants
### `COMPARISON_OPERATORS` <a id="constant-COMPARISON_OPERATORS"></a> <a id="COMPARISON_OPERATORS-constant"></a>
Not documented.

### `FALSEY_TYPES` <a id="constant-FALSEY_TYPES"></a> <a id="FALSEY_TYPES-constant"></a>
Not documented.

### `FLIPPED` <a id="constant-FLIPPED"></a> <a id="FLIPPED-constant"></a>
Not documented.

### `LITERAL_TYPES` <a id="constant-LITERAL_TYPES"></a> <a id="LITERAL_TYPES-constant"></a>
Not documented.

### `NUMERIC_OPERATORS` <a id="constant-NUMERIC_OPERATORS"></a> <a id="NUMERIC_OPERATORS-constant"></a>
Not documented.

### `NUMERIC_TYPES` <a id="constant-NUMERIC_TYPES"></a> <a id="NUMERIC_TYPES-constant"></a>
Not documented.

### `OPERATORS` <a id="constant-OPERATORS"></a> <a id="OPERATORS-constant"></a>
Not documented.

### `REASONS` <a id="constant-REASONS"></a> <a id="REASONS-constant"></a>
Not documented.

### `REASON_MESSAGES` <a id="constant-REASON_MESSAGES"></a> <a id="REASON_MESSAGES-constant"></a>
Not documented.

### `SUBJECT_KINDS` <a id="constant-SUBJECT_KINDS"></a> <a id="SUBJECT_KINDS-constant"></a>
Not documented.

### `VERSION` <a id="constant-VERSION"></a> <a id="VERSION-constant"></a>
Not documented.

## Public Class Methods
### `comparison_constraint(node, name)` <a id="method-c-comparison_constraint"></a> <a id="comparison_constraint-class_method"></a>
Not documented.

### `for_node(node)` <a id="method-c-for_node"></a> <a id="for_node-class_method"></a>
Derives the normalized constraint of one atomic condition, or nil when the
expression is outside the supported vocabulary.

### `literal_for(node)` <a id="method-c-literal_for"></a> <a id="literal_for-class_method"></a>
String equality stays unsupported in v1 so that encoding and mutability
questions cannot turn into an impossibility claim.

### `message(reason)` <a id="method-c-message"></a> <a id="message-class_method"></a>
Not documented.

### `mixed_numeric_literals?(left, right)` <a id="method-c-mixed_numeric_literals-3F"></a> <a id="mixed_numeric_literals?-class_method"></a>
- **@return** [Boolean]

### `nil_constraint(node)` <a id="method-c-nil_constraint"></a> <a id="nil_constraint-class_method"></a>
Not documented.

### `numeric?(literal)` <a id="method-c-numeric-3F"></a> <a id="numeric?-class_method"></a>
- **@return** [Boolean]

### `same_literal?(left, right)` <a id="method-c-same_literal-3F"></a> <a id="same_literal?-class_method"></a>
- **@return** [Boolean]

### `simple_call?(node)` <a id="method-c-simple_call-3F"></a> <a id="simple_call?-class_method"></a>
- **@return** [Boolean]

### `single_argument(node)` <a id="method-c-single_argument"></a> <a id="single_argument-class_method"></a>
Not documented.

### `subject_for(node)` <a id="method-c-subject_for"></a> <a id="subject_for-class_method"></a>
Only unambiguously identifiable storage locations become subjects. Method-call
receivers stay unsupported: a repeated call may return a different value or
have side effects (see the v1 constraint scope).

### `subject_key(subject)` <a id="method-c-subject_key"></a> <a id="subject_key-class_method"></a>
Not documented.

### `symbolize(value)` <a id="method-c-symbolize"></a> <a id="symbolize-class_method"></a>
Not documented.

### `usable?(constraint)` <a id="method-c-usable-3F"></a> <a id="usable?-class_method"></a>
- **@return** [Boolean]

### `valid_literal_value?(literal)` <a id="method-c-valid_literal_value-3F"></a> <a id="valid_literal_value?-class_method"></a>
- **@return** [Boolean]
