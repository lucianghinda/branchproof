# Class Branchproof::Constraints::Solver <a id="class-Branchproof-Constraints-Solver"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/constraints.rb |

Accumulates the constraints one decision-table rule requires and reports the
first proven contradiction. Subjects never interact with each other.

## Public Instance Methods
### `add(constraint, truth)` <a id="method-i-add"></a> <a id="add-instance_method"></a>
Returns a reason code when the rule became unsatisfiable, otherwise nil.

### `initialize()` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Solver] a new instance of Solver
