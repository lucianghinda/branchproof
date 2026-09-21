# Class Branchproof::RSpecAdapter <a id="class-Branchproof-RSpecAdapter"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/rspec_adapter.rb |

Bridges one serial RSpec run to Runtime lifecycle ownership.

## Constants
### `FORBIDDEN_OPTIONS` <a id="constant-FORBIDDEN_OPTIONS"></a> <a id="FORBIDDEN_OPTIONS-constant"></a>
Not documented.

## Attributes
### `active_adapter` [RW] <a id="attribute-c-active_adapter"></a> <a id="active_adapter-class_method"></a>
Returns the value of attribute active_adapter.

### `runner_adapter` [RW] <a id="attribute-c-runner_adapter"></a> <a id="runner_adapter-class_method"></a>
Returns the value of attribute runner_adapter.

### `late_execution_error` [R] <a id="attribute-i-late_execution_error"></a> <a id="late_execution_error-instance_method"></a>
Returns the value of attribute late_execution_error.

### `tests` [R] <a id="attribute-i-tests"></a> <a id="tests-instance_method"></a>
Returns the value of attribute tests.

## Public Instance Methods
### `enter_runner!(runner)` <a id="method-i-enter_runner-21"></a> <a id="enter_runner!-instance_method"></a>
Not documented.

### `example_finished(notification)` <a id="method-i-example_finished"></a> <a id="example_finished-instance_method"></a>
Not documented.

### `example_started(notification)` <a id="method-i-example_started"></a> <a id="example_started-instance_method"></a>
Not documented.

### `initialize(runtime:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [RSpecAdapter] a new instance of RSpecAdapter

### `reject_execution!(message)` <a id="method-i-reject_execution-21"></a> <a id="reject_execution!-instance_method"></a>
- **@raise** [@run_error]

### `run(test_files:, runner_args:, on_complete:, before_load: = nil, after_load: = nil, test_selection_explicit: = false)` <a id="method-i-run"></a> <a id="run-instance_method"></a>
rubocop:disable-next Metrics/ParameterLists

### `validate_runner!()` <a id="method-i-validate_runner-21"></a> <a id="validate_runner!-instance_method"></a>
Not documented.
