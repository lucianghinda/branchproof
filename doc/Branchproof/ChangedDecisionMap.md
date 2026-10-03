# Class Branchproof::ChangedDecisionMap <a id="class-Branchproof-ChangedDecisionMap"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/changed_decision_map.rb |

Maps changed lines to current decision records using Prism byte locations.
rubocop:disable-next Metrics/ClassLength -- AST ownership rules share the
parsed current source and hunk ranges.

## Constants
### `CONTROL_NODES` <a id="constant-CONTROL_NODES"></a> <a id="CONTROL_NODES-constant"></a>
Not documented.

## Public Instance Methods
### `call(bytes:, path:, decisions:, hunks:, old_bytes: = "")` <a id="method-i-call"></a> <a id="call-instance_method"></a>
rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/MethodLength, Metrics/PerceivedComplexity -- Keeps one Prism walk
across all supported contexts.
