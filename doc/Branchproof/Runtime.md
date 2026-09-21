# Module Branchproof::Runtime <a id="module-Branchproof-Runtime"></a>

|  |  |
| --- | --- |
| **Extended by** | [Branchproof::DefaultRuntime](DefaultRuntime.md), [Branchproof::ExceptionRuntime](ExceptionRuntime.md), [Branchproof::ExtendedAlternativeRuntime](ExtendedAlternativeRuntime.md), [Branchproof::IterationRuntime](IterationRuntime.md), [Branchproof::RuntimeFlow](RuntimeFlow.md), [Branchproof::ValueRuntime](ValueRuntime.md) |
| **Defined in** | lib/branchproof/runtime.rb |

Process-local execution recorder. It deliberately never coerces or stores
application values: Ruby's conditional expression is used for truthiness.
Captures condition evaluations while preserving application values.

## Constants
### `FRAME_STATE_KEY` <a id="constant-FRAME_STATE_KEY"></a> <a id="FRAME_STATE_KEY-constant"></a>
Not documented.

## Public Class Methods
### `boot(evidence:)` <a id="method-c-boot"></a> <a id="boot-class_method"></a>
Not documented.

### `condition(decision_id, index, value)` <a id="method-c-condition"></a> <a id="condition-class_method"></a>
Not documented.

### `context(test_id:, phase:)` <a id="method-c-context"></a> <a id="context-class_method"></a>
Not documented.

### `default_binding(decision_id, index)` <a id="method-c-default_binding"></a> <a id="default_binding-class_method"></a>
Not documented.

### `diagnostics()` <a id="method-c-diagnostics"></a> <a id="diagnostics-class_method"></a>
Not documented.

### `dispatch_path(decision_id, value, raised)` <a id="method-c-dispatch_path"></a> <a id="dispatch_path-class_method"></a>
Not documented.

### `enter(decision_id)` <a id="method-c-enter"></a> <a id="enter-class_method"></a>
Not documented.

### `exception_enter(decision_id, unhandled_index)` <a id="method-c-exception_enter"></a> <a id="exception_enter-class_method"></a>
Not documented.

### `exception_finish(decision_id, value)` <a id="method-c-exception_finish"></a> <a id="exception_finish-class_method"></a>
Not documented.

### `exception_leave(decision_id)` <a id="method-c-exception_leave"></a> <a id="exception_leave-class_method"></a>
Not documented.

### `exception_path(decision_id, index)` <a id="method-c-exception_path"></a> <a id="exception_path-class_method"></a>
Not documented.

### `exception_unhandled(decision_id)` <a id="method-c-exception_unhandled"></a> <a id="exception_unhandled-class_method"></a>
Not documented.

### `exception_value(decision_id, value, index)` <a id="method-c-exception_value"></a> <a id="exception_value-class_method"></a>
Not documented.

### `finish(decision_id, value)` <a id="method-c-finish"></a> <a id="finish-class_method"></a>
Not documented.

### `flow_assignment_finish(decision_id, value, default_path = nil)` <a id="method-c-flow_assignment_finish"></a> <a id="flow_assignment_finish-class_method"></a>
Not documented.

### `flow_assignment_path(decision_id, index)` <a id="method-c-flow_assignment_path"></a> <a id="flow_assignment_path-class_method"></a>
Not documented.

### `flow_assignment_receiver(decision_id, receiver)` <a id="method-c-flow_assignment_receiver"></a> <a id="flow_assignment_receiver-class_method"></a>
Not documented.

### `flow_candidate(decision_id, index)` <a id="method-c-flow_candidate"></a> <a id="flow_candidate-class_method"></a>
Not documented.

### `flow_finish(decision_id, value, default_path = nil)` <a id="method-c-flow_finish"></a> <a id="flow_finish-class_method"></a>
Not documented.

### `flow_iteration_begin(decision_id, receiver, alternative_count = 2)` <a id="method-c-flow_iteration_begin"></a> <a id="flow_iteration_begin-class_method"></a>
Not documented.

### `flow_iteration_callback(decision_id, alternative_count = 2)` <a id="method-c-flow_iteration_callback"></a> <a id="flow_iteration_callback-class_method"></a>
rubocop:disable-next Metrics/MethodLength

### `flow_iteration_finish(decision_id, value, default_path = nil)` <a id="method-c-flow_iteration_finish"></a> <a id="flow_iteration_finish-class_method"></a>
Not documented.

### `flow_iteration_leave(decision_id)` <a id="method-c-flow_iteration_leave"></a> <a id="flow_iteration_leave-class_method"></a>
Not documented.

### `flow_path(decision_id, index)` <a id="method-c-flow_path"></a> <a id="flow_path-class_method"></a>
Not documented.

### `flow_receiver(decision_id, receiver)` <a id="method-c-flow_receiver"></a> <a id="flow_receiver-class_method"></a>
Not documented.

### `flow_select(decision_id, index)` <a id="method-c-flow_select"></a> <a id="flow_select-class_method"></a>
Not documented.

### `flow_selected(decision_id)` <a id="method-c-flow_selected"></a> <a id="flow_selected-class_method"></a>
Not documented.

### `leave(decision_id)` <a id="method-c-leave"></a> <a id="leave-class_method"></a>
Not documented.

### `register_test(test:)` <a id="method-c-register_test"></a> <a id="register_test-class_method"></a>
Not documented.

### `set_alternative_count(decision_id, count)` <a id="method-c-set_alternative_count"></a> <a id="set_alternative_count-class_method"></a>
rubocop:enable Style/CaseEquality, Metrics/CyclomaticComplexity,
Metrics/PerceivedComplexity

### `snapshot()` <a id="method-c-snapshot"></a> <a id="snapshot-class_method"></a>
Not documented.

### `test_phase_counts()` <a id="method-c-test_phase_counts"></a> <a id="test_phase_counts-class_method"></a>
Not documented.

### `value_path(decision_id, value, domain)` <a id="method-c-value_path"></a> <a id="value_path-class_method"></a>
rubocop:disable-next Metrics/MethodLength -- trace state branches are
explicit. rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity,
Metrics/PerceivedComplexity -- domain dispatch mirrors the observable value
contract.
