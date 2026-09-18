# Module Branchproof::ValueRuntime <a id="module-Branchproof-ValueRuntime"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/value_runtime.rb |

Runtime mapping for value observations.

## Public Class Methods
### `comparison_index(value)` <a id="method-c-comparison_index"></a> <a id="comparison_index-class_method"></a>
rubocop:disable Style/CaseEquality, Metrics/CyclomaticComplexity,
Metrics/PerceivedComplexity

## Public Instance Methods
### `dispatch_path(decision_id, value, raised)` <a id="method-i-dispatch_path"></a> <a id="dispatch_path-instance_method"></a>
Not documented.

### `set_alternative_count(decision_id, count)` <a id="method-i-set_alternative_count"></a> <a id="set_alternative_count-instance_method"></a>
rubocop:enable Style/CaseEquality, Metrics/CyclomaticComplexity,
Metrics/PerceivedComplexity

### `value_path(decision_id, value, domain)` <a id="method-i-value_path"></a> <a id="value_path-instance_method"></a>
rubocop:disable-next Metrics/MethodLength -- trace state branches are
explicit. rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/PerceivedComplexity -- domain dispatch mirrors the observable value
contract.
