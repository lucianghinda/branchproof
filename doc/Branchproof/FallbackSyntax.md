# Module Branchproof::FallbackSyntax <a id="module-Branchproof-FallbackSyntax"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/fallback_syntax.rb |

A value-context `||` chain that ends in an always-truthy literal returns the
first truthy operand and is never false. It is inventoried as alternatives
(which operand supplied the value), not as a Boolean decision. Terminal guards
instead measure the left predicate that selects the RHS.

## Constants
### `JUMP_NODES` <a id="constant-JUMP_NODES"></a> <a id="JUMP_NODES-constant"></a>
A jump never supplies a value, so it cannot be a fallback operand.
