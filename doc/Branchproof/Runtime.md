# Module Branchproof::Runtime <a id="module-Branchproof-Runtime"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/runtime.rb |

Process-local execution recorder. It deliberately never coerces or stores
application values: Ruby's conditional expression is used for truthiness.
Captures condition evaluations while preserving application values.

## Public Class Methods
### `boot(evidence:)` <a id="method-c-boot"></a> <a id="boot-class_method"></a>
Not documented.

### `condition(decision_id, index, value)` <a id="method-c-condition"></a> <a id="condition-class_method"></a>
Not documented.

### `context(test_id:, phase:)` <a id="method-c-context"></a> <a id="context-class_method"></a>
Not documented.

### `diagnostics()` <a id="method-c-diagnostics"></a> <a id="diagnostics-class_method"></a>
Not documented.

### `enter(decision_id)` <a id="method-c-enter"></a> <a id="enter-class_method"></a>
Not documented.

### `finish(decision_id, value)` <a id="method-c-finish"></a> <a id="finish-class_method"></a>
Not documented.

### `leave(decision_id)` <a id="method-c-leave"></a> <a id="leave-class_method"></a>
Not documented.

### `register_test(test:)` <a id="method-c-register_test"></a> <a id="register_test-class_method"></a>
Not documented.

### `snapshot()` <a id="method-c-snapshot"></a> <a id="snapshot-class_method"></a>
Not documented.
