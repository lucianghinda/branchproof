# Module Branchproof::FallbackInstrumentation <a id="module-Branchproof-FallbackInstrumentation"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/fallback_instrumentation.rb |

Wraps each fallback operand so the runtime sees the operand's own value. `||`
still short-circuits, so later operands are never evaluated early.
