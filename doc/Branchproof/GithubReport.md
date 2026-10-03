# Class Branchproof::GithubReport <a id="class-Branchproof-GithubReport"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/github_report.rb |

GitHub Actions output: workflow-command annotations for the ranked gaps and a
Markdown job summary. Both reuse the summary view's ranking and wording.

## Constants
### `MARKDOWN_ROWS` <a id="constant-MARKDOWN_ROWS"></a> <a id="MARKDOWN_ROWS-constant"></a>
Not documented.

## Public Instance Methods
### `annotations(path_prefix: = @path_prefix)` <a id="method-i-annotations"></a> <a id="annotations-instance_method"></a>
Workflow commands for stdout, one warning per ranked decision gap.

### `initialize(document:, level:, coordinator:, selection: = ReportSelection.new, path_prefix: = nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
path_prefix maps project-relative paths to repository-relative ones when the
project is not at the repository root.
- **@return** [GithubReport] a new instance of GithubReport

### `step_summary()` <a id="method-i-step_summary"></a> <a id="step_summary-instance_method"></a>
Markdown for $GITHUB_STEP_SUMMARY.
