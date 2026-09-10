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

## Public Class Methods
### `from_document(document:, level: = nil, view: = :decisions, missing_only: = false)` <a id="method-c-from_document"></a> <a id="from_document-class_method"></a>
Not documented.

## Public Instance Methods
### `condition_coverage_evidence(decision_id:, condition_id:)` <a id="method-i-condition_coverage_evidence"></a> <a id="condition_coverage_evidence-instance_method"></a>
Returns condition-value evidence for focused renderers without exposing the
report's internal document traversal or mutating saved records.

### `condition_explanation(decision_id:, condition_id:)` <a id="method-i-condition_explanation"></a> <a id="condition_explanation-instance_method"></a>
Shares the existing missing-case wording with focused terminal views.

### `coverage_ladder_lines()` <a id="method-i-coverage_ladder_lines"></a> <a id="coverage_ladder_lines-instance_method"></a>
Render the shared ladder in every terminal view.

### `coverage_status_label(status)` <a id="method-i-coverage_status_label"></a> <a id="coverage_status_label-instance_method"></a>
Not documented.

### `diagnostic_message(diagnostic)` <a id="method-i-diagnostic_message"></a> <a id="diagnostic_message-instance_method"></a>
Formats source context consistently in live and saved terminal views.

### `exit_code()` <a id="method-i-exit_code"></a> <a id="exit_code-instance_method"></a>
Not documented.

### `initialize(inventory:, evidence:, analysis:, minima:, baseline:, diagnostics:, level: = 3, missing_only: = false, view: = :decisions, run_metadata: = {}, saved_document: = nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Report] a new instance of Report

### `write(io:, format:)` <a id="method-i-write"></a> <a id="write-instance_method"></a>
- **@raise** [ArgumentError]
