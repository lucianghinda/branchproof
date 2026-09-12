# Module Branchproof::DecisionSyntax <a id="module-Branchproof-DecisionSyntax"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/decision_syntax.rb |

Discovers control-flow expressions whose truth is not represented by an
ordinary Prism IfNode.  The records intentionally contain byte ranges and
scalar metadata only; Prism nodes must not escape the source pass.

## Constants
### `AND_WRITE_NODE_CLASSES` <a id="constant-AND_WRITE_NODE_CLASSES"></a> <a id="AND_WRITE_NODE_CLASSES-constant"></a>
Not documented.

### `OR_WRITE_NODE_CLASSES` <a id="constant-OR_WRITE_NODE_CLASSES"></a> <a id="OR_WRITE_NODE_CLASSES-constant"></a>
Not documented.

## Public Instance Methods
### `flow_decisions_for(program, bytes, source_id, file_reasons = [], encoding = "UTF-8", nodes: = nil)` <a id="method-i-flow_decisions_for"></a> <a id="flow_decisions_for-instance_method"></a>
nodes: flow-decision nodes already collected by a caller's own AST walk
(Source merges this discovery into one pass). Falls back to its own walk when
nothing is passed in, so this method still works standalone.
