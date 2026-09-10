# Module Branchproof::DecisionSyntax <a id="module-Branchproof-DecisionSyntax"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/decision_syntax.rb |

Discovers control-flow expressions whose truth is not represented by an
ordinary Prism IfNode.  The records intentionally contain byte ranges and
scalar metadata only; Prism nodes must not escape the source pass.

## Constants
### `AND_WRITE_NODE_NAMES` <a id="constant-AND_WRITE_NODE_NAMES"></a> <a id="AND_WRITE_NODE_NAMES-constant"></a>
Not documented.

### `OR_WRITE_NODE_NAMES` <a id="constant-OR_WRITE_NODE_NAMES"></a> <a id="OR_WRITE_NODE_NAMES-constant"></a>
Not documented.

## Public Instance Methods
### `flow_decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8")` <a id="method-i-flow_decisions_for"></a> <a id="flow_decisions_for-instance_method"></a>
Not documented.
