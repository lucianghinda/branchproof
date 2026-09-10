# Class Branchproof::Evidence <a id="class-Branchproof-Evidence"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/evidence.rb |

Validates, groups, and merges adapter-neutral execution evidence. Stores
validated observations and merges compatible worker snapshots.

## Constants
### `CRITERION_VERSION` <a id="constant-CRITERION_VERSION"></a> <a id="CRITERION_VERSION-constant"></a>
Not documented.

### `SCHEMA_VERSION` <a id="constant-SCHEMA_VERSION"></a> <a id="SCHEMA_VERSION-constant"></a>
Not documented.

### `TOOL_VERSION` <a id="constant-TOOL_VERSION"></a> <a id="TOOL_VERSION-constant"></a>
Not documented.

## Attributes
### `inventory` [R] <a id="attribute-i-inventory"></a> <a id="inventory-instance_method"></a>
Returns the value of attribute inventory.

### `run_id` [R] <a id="attribute-i-run_id"></a> <a id="run_id-instance_method"></a>
Returns the value of attribute run_id.

## Public Instance Methods
### `diagnose(diagnostic:)` <a id="method-i-diagnose"></a> <a id="diagnose-instance_method"></a>
Not documented.

### `initialize(inventory:, limits:, run_id:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Evidence] a new instance of Evidence

### `merge(snapshot:)` <a id="method-i-merge"></a> <a id="merge-instance_method"></a>
Not documented.

### `record(execution:)` <a id="method-i-record"></a> <a id="record-instance_method"></a>
Not documented.

### `register_test(test:)` <a id="method-i-register_test"></a> <a id="register_test-instance_method"></a>
Not documented.

### `snapshot()` <a id="method-i-snapshot"></a> <a id="snapshot-instance_method"></a>
Not documented.
