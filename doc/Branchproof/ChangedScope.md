# Class Branchproof::ChangedScope <a id="class-Branchproof-ChangedScope"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/changed_scope.rb |

Describes tracked files and current decision IDs affected by the direct
commit-to-worktree comparison.

## Public Instance Methods
### `call(inventory:)` <a id="method-i-call"></a> <a id="call-instance_method"></a>
rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/MethodLength, Metrics/PerceivedComplexity -- Coordinates Git capture,
inventory checks, and ordered membership.

### `initialize(root:, ref:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [ChangedScope] a new instance of ChangedScope
