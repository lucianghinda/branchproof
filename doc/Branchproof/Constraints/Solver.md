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

### `add_prepared(constraint, truth)` <a id="method-i-add_prepared"></a> <a id="add_prepared-instance_method"></a>
Adds a constraint that has already been symbolized and validated by
<code>usable?</code>. Source inventory can use this path after preparing each
leaf once instead of repeating normalization for every solver state.

### `initialize()` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Solver] a new instance of Solver
