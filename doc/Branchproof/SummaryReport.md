# Class Branchproof::SummaryReport <a id="class-Branchproof-SummaryReport"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/summary_report.rb |

Terminal view that lists the largest coverage gaps first.

## Constants
### `EXPRESSION_WIDTH` <a id="constant-EXPRESSION_WIDTH"></a> <a id="EXPRESSION_WIDTH-constant"></a>
Not documented.

### `ORDER_NOTE` <a id="constant-ORDER_NOTE"></a> <a id="ORDER_NOTE-constant"></a>
Not documented.

### `RULE_LABELS` <a id="constant-RULE_LABELS"></a> <a id="RULE_LABELS-constant"></a>
Not documented.

### `SHOWN_TESTS` <a id="constant-SHOWN_TESTS"></a> <a id="SHOWN_TESTS-constant"></a>
Not documented.

## Public Class Methods
### `case_lines(decision, coordinator)` <a id="method-c-case_lines"></a> <a id="case_lines-class_method"></a>
One line per missing case: decision-table rules when some are missing,
otherwise unproven conditions; then missing alternatives.

### `gap_summary(decision)` <a id="method-c-gap_summary"></a> <a id="gap_summary-class_method"></a>
Shared wording for terminal rows and GitHub output.

### `one_line(text, width = EXPRESSION_WIDTH)` <a id="method-c-one_line"></a> <a id="one_line-class_method"></a>
Not documented.

### `rule_text(rule, expressions, coordinator)` <a id="method-c-rule_text"></a> <a id="rule_text-class_method"></a>
Not documented.

## Public Instance Methods
### `initialize(document:, level:, coordinator:, missing_only: = false, selection: = ReportSelection.new)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [SummaryReport] a new instance of SummaryReport

### `render()` <a id="method-i-render"></a> <a id="render-instance_method"></a>
Not documented.
