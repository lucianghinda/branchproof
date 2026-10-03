# Class Branchproof::SummaryRanking <a id="class-Branchproof-SummaryRanking"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/summary_ranking.rb |

Ranks supported decisions and source files by missing coverage obligations.

Order: unexecuted decisions first, then more missing obligations
(decision-table rules, unproven MC/DC conditions, missing alternatives), then
source path, line, column, and ID. The order is a count, not a risk estimate.
Unsupported decisions are counted but never ranked.

## Attributes
### `index` [R] <a id="attribute-i-index"></a> <a id="index-instance_method"></a>
Returns the value of attribute index.

## Public Instance Methods
### `available?()` <a id="method-i-available-3F"></a> <a id="available?-instance_method"></a>
- **@return** [Boolean]

### `decisions()` <a id="method-i-decisions"></a> <a id="decisions-instance_method"></a>
All supported decisions in the selection, ranked.

### `files()` <a id="method-i-files"></a> <a id="files-instance_method"></a>
Not documented.

### `gaps()` <a id="method-i-gaps"></a> <a id="gaps-instance_method"></a>
Not documented.

### `initialize(document:, selection: = ReportSelection.new)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [SummaryRanking] a new instance of SummaryRanking

### `unsupported_count()` <a id="method-i-unsupported_count"></a> <a id="unsupported_count-instance_method"></a>
Not documented.
