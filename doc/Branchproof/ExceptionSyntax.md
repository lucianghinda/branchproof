# Module Branchproof::ExceptionSyntax <a id="module-Branchproof-ExceptionSyntax"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/exception_syntax.rb |

Replaces unsupported standalone rescue-clause records with decisions for
Ruby's enclosing protected region.  Ruby chooses a rescue clause as part of
executing BeginNode; a RescueNode by itself is not executable syntax.
