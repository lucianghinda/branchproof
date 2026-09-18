# Module Branchproof::ExceptionInstrumentation <a id="module-Branchproof-ExceptionInstrumentation"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/exception_instrumentation.rb |

Textual edits for native rescue control flow.  The edits only add calls at
Ruby's own protected-region and handler boundaries; exception matching, `$!`,
retry, ensure ordering, and nonlocal transfers remain Ruby-owned.
