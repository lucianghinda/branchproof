# Module Branchproof::IterationRuntime <a id="module-Branchproof-IterationRuntime"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/iteration_runtime.rb |

Runtime support for callback based iteration, including lazy receivers whose
callbacks execute after the constructing call has returned.

## Public Instance Methods
### `flow_iteration_begin(decision_id, receiver, alternative_count = 2)` <a id="method-i-flow_iteration_begin"></a> <a id="flow_iteration_begin-instance_method"></a>
Not documented.

### `flow_iteration_callback(decision_id, alternative_count = 2)` <a id="method-i-flow_iteration_callback"></a> <a id="flow_iteration_callback-instance_method"></a>
rubocop:disable-next Metrics/MethodLength

### `flow_iteration_finish(decision_id, value, default_path = nil)` <a id="method-i-flow_iteration_finish"></a> <a id="flow_iteration_finish-instance_method"></a>
Not documented.

### `flow_iteration_leave(decision_id)` <a id="method-i-flow_iteration_leave"></a> <a id="flow_iteration_leave-instance_method"></a>
Not documented.
