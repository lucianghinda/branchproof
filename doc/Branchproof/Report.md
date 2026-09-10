# Class Branchproof::Report <a id="class-Branchproof-Report"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/report.rb |

Renders versioned terminal and JSON analysis reports.

## Constants
### `CRITERION_VERSION` <a id="constant-CRITERION_VERSION"></a> <a id="CRITERION_VERSION-constant"></a>
Not documented.

### `SCHEMA_VERSION` <a id="constant-SCHEMA_VERSION"></a> <a id="SCHEMA_VERSION-constant"></a>
Not documented.

## Public Instance Methods
### `exit_code()` <a id="method-i-exit_code"></a> <a id="exit_code-instance_method"></a>
Not documented.

### `initialize(inventory:, evidence:, analysis:, minima:, baseline:, diagnostics:, level: = 3)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Report] a new instance of Report

### `write(io:, format:)` <a id="method-i-write"></a> <a id="write-instance_method"></a>
- **@raise** [ArgumentError]
