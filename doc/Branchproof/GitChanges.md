# Class Branchproof::GitChanges <a id="class-Branchproof-GitChanges"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/git_changes.rb |

Reads the tracked working-tree delta from a validated commit to the current
index and worktree. Untracked files are intentionally outside this scope.
rubocop:disable-next Metrics/ClassLength -- Git capture phases share one
validated process context.

## Public Instance Methods
### `call(include_patch_lines: = false)` <a id="method-i-call"></a> <a id="call-instance_method"></a>
rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/MethodLength -- Capture order is security-sensitive.

### `initialize(root:, ref:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [GitChanges] a new instance of GitChanges
