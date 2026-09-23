# Class Branchproof::ReportSelection <a id="class-Branchproof-ReportSelection"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/report_selection.rb |

Validates and applies terminal-only report display filters. rubocop:disable
Metrics/ClassLength, Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/MethodLength, Metrics/PerceivedComplexity

## Attributes
### `focus` [R] <a id="attribute-i-focus"></a> <a id="focus-instance_method"></a>
Returns the value of attribute focus.

### `top` [R] <a id="attribute-i-top"></a> <a id="top-instance_method"></a>
Returns the value of attribute top.

## Public Instance Methods
### `active?()` <a id="method-i-active-3F"></a> <a id="active?-instance_method"></a>
- **@return** [Boolean]

### `filter_decisions(decisions, inventory: = {})` <a id="method-i-filter_decisions"></a> <a id="filter_decisions-instance_method"></a>
Not documented.

### `focus_active?()` <a id="method-i-focus_active-3F"></a> <a id="focus_active?-instance_method"></a>
- **@return** [Boolean]

### `focus_label()` <a id="method-i-focus_label"></a> <a id="focus_label-instance_method"></a>
Not documented.

### `initialize(focus: = nil, top: = nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [ReportSelection] a new instance of ReportSelection

### `limit(items)` <a id="method-i-limit"></a> <a id="limit-instance_method"></a>
Not documented.

### `matching_decision_ids(document)` <a id="method-i-matching_decision_ids"></a> <a id="matching_decision_ids-instance_method"></a>
Not documented.

### `sort_key(decision, inventory: = {})` <a id="method-i-sort_key"></a> <a id="sort_key-instance_method"></a>
Not documented.
