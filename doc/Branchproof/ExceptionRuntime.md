# Module Branchproof::ExceptionRuntime <a id="module-Branchproof-ExceptionRuntime"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/exception_runtime.rb |

Record native clause selection and escaping exceptions. Generated wrappers
re-raise the same exception; nonlocal transfers remain aborted observations.

## Public Instance Methods
### `exception_enter(decision_id, unhandled_index)` <a id="method-i-exception_enter"></a> <a id="exception_enter-instance_method"></a>
Not documented.

### `exception_finish(decision_id, value)` <a id="method-i-exception_finish"></a> <a id="exception_finish-instance_method"></a>
Not documented.

### `exception_leave(decision_id)` <a id="method-i-exception_leave"></a> <a id="exception_leave-instance_method"></a>
Not documented.

### `exception_path(decision_id, index)` <a id="method-i-exception_path"></a> <a id="exception_path-instance_method"></a>
Not documented.

### `exception_unhandled(decision_id)` <a id="method-i-exception_unhandled"></a> <a id="exception_unhandled-instance_method"></a>
Not documented.

### `exception_value(decision_id, value, index)` <a id="method-i-exception_value"></a> <a id="exception_value-instance_method"></a>
Not documented.
