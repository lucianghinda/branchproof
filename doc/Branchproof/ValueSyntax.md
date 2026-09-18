# Module Branchproof::ValueSyntax <a id="module-Branchproof-ValueSyntax"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/value_syntax.rb |

Inventory for expressions whose result is itself the observable value. This
deliberately excludes control-flow predicates already owned by Source.

## Constants
### `BOOLEAN_OPERATORS` <a id="constant-BOOLEAN_OPERATORS"></a> <a id="BOOLEAN_OPERATORS-constant"></a>
Not documented.

### `DISPATCH_METHODS` <a id="constant-DISPATCH_METHODS"></a> <a id="DISPATCH_METHODS-constant"></a>
Not documented.

## Public Instance Methods
### `additional_decisions_for(program, bytes, source_id, file_reasons, encoding, decisions:, collected:)` <a id="method-i-additional_decisions_for"></a> <a id="additional_decisions_for-instance_method"></a>
rubocop:disable-next Metrics/ParameterLists -- source seam mirrors
Source#decisions_for.

### `value_decisions_for(program, bytes, source_id, nodes: = nil, occupied_ranges: = {}, file_reasons: = [], encoding: = "UTF-8")` <a id="method-i-value_decisions_for"></a> <a id="value_decisions_for-instance_method"></a>
<code>nodes:</code> is supplied by Source's fused AST walk. It remains
optional for the standalone discovery API used by focused syntax tests.
rubocop:disable-next Metrics/MethodLength, Metrics/ParameterLists -- source
seam mirrors Source#decisions_for.
