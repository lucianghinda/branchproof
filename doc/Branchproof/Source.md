# Class Branchproof::Source <a id="class-Branchproof-Source"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Includes** | [Branchproof::DecisionSyntax](DecisionSyntax.md), [Branchproof::DefaultSyntax](DefaultSyntax.md), [Branchproof::ExceptionSyntax](ExceptionSyntax.md), [Branchproof::IterationSyntax](IterationSyntax.md), [Branchproof::ValueSyntax](ValueSyntax.md) |
| **Defined in** | lib/branchproof/source.rb |

Inventories supported condition and decision occurrences from Ruby files.

## Attributes
### `limits` [R] <a id="attribute-i-limits"></a> <a id="limits-instance_method"></a>
Returns the value of attribute limits.

### `root` [R] <a id="attribute-i-root"></a> <a id="root-instance_method"></a>
Returns the value of attribute root.

## Public Instance Methods
### `initialize(root:, limits:)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Source] a new instance of Source

### `inventory(paths:)` <a id="method-i-inventory"></a> <a id="inventory-instance_method"></a>
- **@raise** [ArgumentError]

### `value_decisions_for(program, bytes, source_id, nodes: = nil, occupied_ranges: = {}, file_reasons: = [], encoding: = "UTF-8")` <a id="method-i-value_decisions_for"></a> <a id="value_decisions_for-instance_method"></a>
<code>nodes:</code> is supplied by Source's fused AST walk. It remains
optional for the standalone discovery API used by focused syntax tests.
rubocop:disable-next Metrics/MethodLength, Metrics/ParameterLists -- source
seam mirrors Source#decisions_for.
