# Class Branchproof::Doctor <a id="class-Branchproof-Doctor"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/branchproof/doctor.rb |

Checks static setup facts and renders diagnostics without executing project
code.

## Constants
### `ERROR_DOCUMENT` <a id="constant-ERROR_DOCUMENT"></a> <a id="ERROR_DOCUMENT-constant"></a>
Not documented.

### `FRAMEWORK_GEMS` <a id="constant-FRAMEWORK_GEMS"></a> <a id="FRAMEWORK_GEMS-constant"></a>
Not documented.

### `LIMITATIONS` <a id="constant-LIMITATIONS"></a> <a id="LIMITATIONS-constant"></a>
Not documented.

## Public Class Methods
### `error(message)` <a id="method-c-error"></a> <a id="error-class_method"></a>
Not documented.

### `terminal(document)` <a id="method-c-terminal"></a> <a id="terminal-class_method"></a>
Not documented.

## Public Instance Methods
### `document(source_files:, test_files:)` <a id="method-i-document"></a> <a id="document-instance_method"></a>
Not documented.

### `initialize(options:, runtime: = { engine: RUBY_ENGINE, version: RUBY_VERSION }, loaded_features: = $LOADED_FEATURES, gem_sources: = { activated: Gem.loaded_specs,
                                  discoverable: ->(name) { Gem::Specification.find_all_by_name(name) } })` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Doctor] a new instance of Doctor
