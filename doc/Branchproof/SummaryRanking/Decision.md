# Class Branchproof::SummaryRanking::Decision <a id="class-Branchproof-SummaryRanking-Decision"></a>

|  |  |
| --- | --- |
| **Inherits** | Struct |
| **Defined in** | lib/branchproof/summary_ranking.rb |

## Attributes
### `alternatives` [RW] <a id="attribute-i-alternatives"></a> <a id="alternatives-instance_method"></a>
Returns the value of attribute alternatives
- **@return** [Object] the current value of alternatives

### `column` [RW] <a id="attribute-i-column"></a> <a id="column-instance_method"></a>
Returns the value of attribute column
- **@return** [Object] the current value of column

### `conditions` [RW] <a id="attribute-i-conditions"></a> <a id="conditions-instance_method"></a>
Returns the value of attribute conditions
- **@return** [Object] the current value of conditions

### `context` [RW] <a id="attribute-i-context"></a> <a id="context-instance_method"></a>
Returns the value of attribute context
- **@return** [Object] the current value of context

### `expression` [RW] <a id="attribute-i-expression"></a> <a id="expression-instance_method"></a>
Returns the value of attribute expression
- **@return** [Object] the current value of expression

### `id` [RW] <a id="attribute-i-id"></a> <a id="id-instance_method"></a>
Returns the value of attribute id
- **@return** [Object] the current value of id

### `kind` [RW] <a id="attribute-i-kind"></a> <a id="kind-instance_method"></a>
Returns the value of attribute kind
- **@return** [Object] the current value of kind

### `line` [RW] <a id="attribute-i-line"></a> <a id="line-instance_method"></a>
Returns the value of attribute line
- **@return** [Object] the current value of line

### `missing_alternatives` [RW] <a id="attribute-i-missing_alternatives"></a> <a id="missing_alternatives-instance_method"></a>
Returns the value of attribute missing_alternatives
- **@return** [Object] the current value of missing_alternatives

### `missing_rules` [RW] <a id="attribute-i-missing_rules"></a> <a id="missing_rules-instance_method"></a>
Returns the value of attribute missing_rules
- **@return** [Object] the current value of missing_rules

### `relative_path` [RW] <a id="attribute-i-relative_path"></a> <a id="relative_path-instance_method"></a>
Returns the value of attribute relative_path
- **@return** [Object] the current value of relative_path

### `required_rules` [RW] <a id="attribute-i-required_rules"></a> <a id="required_rules-instance_method"></a>
Returns the value of attribute required_rules
- **@return** [Object] the current value of required_rules

### `table_calculated` [RW] <a id="attribute-i-table_calculated"></a> <a id="table_calculated-instance_method"></a>
Returns the value of attribute table_calculated
- **@return** [Object] the current value of table_calculated

### `test_ids` [RW] <a id="attribute-i-test_ids"></a> <a id="test_ids-instance_method"></a>
Returns the value of attribute test_ids
- **@return** [Object] the current value of test_ids

### `unexecuted` [RW] <a id="attribute-i-unexecuted"></a> <a id="unexecuted-instance_method"></a>
Returns the value of attribute unexecuted
- **@return** [Object] the current value of unexecuted

### `unproven_conditions` [RW] <a id="attribute-i-unproven_conditions"></a> <a id="unproven_conditions-instance_method"></a>
Returns the value of attribute unproven_conditions
- **@return** [Object] the current value of unproven_conditions

## Public Instance Methods
### `cases_to_test()` <a id="method-i-cases_to_test"></a> <a id="cases_to_test-instance_method"></a>
One new observation covers at most one missing rule, so missing rules are an
exact case count. Without missing rules (no table, or only impossible rules
left), each unproven condition or alternative counts.

### `gap?()` <a id="method-i-gap-3F"></a> <a id="gap?-instance_method"></a>
- **@return** [Boolean]

### `missing_total()` <a id="method-i-missing_total"></a> <a id="missing_total-instance_method"></a>
Not documented.

### `rule_cases?()` <a id="method-i-rule_cases-3F"></a> <a id="rule_cases?-instance_method"></a>
- **@return** [Boolean]
