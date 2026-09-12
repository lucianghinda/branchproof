# Class Branchproof::Analyzer <a id="class-Branchproof-Analyzer"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/analyzer.rb |

Performs the Boolean, occurrence-level masking analysis. It deliberately
accepts plain records so the core does not depend on Minitest or Runtime.

## Constants
### `CRITERION` <a id="constant-CRITERION"></a> <a id="CRITERION-constant"></a>
Not documented.

## Public Instance Methods
### `call()` <a id="method-i-call"></a> <a id="call-instance_method"></a>
Not documented.

### `initialize(inventory:, evidence:, limits:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Analyzer] a new instance of Analyzer

### `missing(decision_id:, condition_index:)` <a id="method-i-missing"></a> <a id="missing-instance_method"></a>
Not documented.

### `pair?(decision_id:, condition_index:, left:, right:, masks: = nil)` <a id="method-i-pair-3F"></a> <a id="pair?-instance_method"></a>
- **@return** [Boolean]
