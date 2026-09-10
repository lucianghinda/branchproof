# Class Branchproof::Instrumenter <a id="class-Branchproof-Instrumenter"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/instrumenter.rb |

Applies the smallest possible source edits around inventoried expressions. The
edits are deliberately textual: Prism owns the ranges, while this class never
evaluates application code or introduces a Ruby scope.

## Constants
### `RUNTIME` <a id="constant-RUNTIME"></a> <a id="RUNTIME-constant"></a>
Not documented.

## Public Instance Methods
### `rewrite(unit:)` <a id="method-i-rewrite"></a> <a id="rewrite-instance_method"></a>
Not documented.
