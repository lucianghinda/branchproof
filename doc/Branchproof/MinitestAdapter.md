# Class Branchproof::MinitestAdapter <a id="class-Branchproof-MinitestAdapter"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/minitest_adapter.rb |

Bridges one serial Minitest run to Runtime lifecycle ownership.

## Attributes
### `active_adapter` [RW] <a id="attribute-c-active_adapter"></a> <a id="active_adapter-class_method"></a>
Returns the value of attribute active_adapter.

### `tests` [R] <a id="attribute-i-tests"></a> <a id="tests-instance_method"></a>
Returns the value of attribute tests.

## Public Instance Methods
### `initialize(runtime:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [MinitestAdapter] a new instance of MinitestAdapter

### `run(test_files:, runner_args:, on_complete:, before_load: = nil)` <a id="method-i-run"></a> <a id="run-instance_method"></a>
Not documented.

### `validate_runner!()` <a id="method-i-validate_runner-21"></a> <a id="validate_runner!-instance_method"></a>
- **@raise** [ArgumentError]
