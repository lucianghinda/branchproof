# Module Branchproof::Worker <a id="module-Branchproof-Worker"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/worker.rb |

Runs one isolated test worker and atomically exports its result.

## Public Class Methods
### `adapter_for(project, runtime)` <a id="method-c-adapter_for"></a> <a id="adapter_for-class_method"></a>
Not documented.

### `boot_project(project)` <a id="method-c-boot_project"></a> <a id="boot_project-class_method"></a>
Not documented.

### `child_process(config_path)` <a id="method-c-child_process"></a> <a id="child_process-class_method"></a>
Not documented.

### `completion_result(baseline:, project:, rails_metadata:, evidence:, tests:, diagnostics:)` <a id="method-c-completion_result"></a> <a id="completion_result-class_method"></a>
This result boundary intentionally carries the complete worker payload.
rubocop:disable-next Metrics/ParameterLists

### `guard_late_rspec_execution(adapter, payload)` <a id="method-c-guard_late_rspec_execution"></a> <a id="guard_late_rspec_execution-class_method"></a>
Installed before application hooks, so this runs after their at_exit work. A
rescued second runner must still invalidate the already-exported result.

### `incomplete_evidence(evidence, diagnostics)` <a id="method-c-incomplete_evidence"></a> <a id="incomplete_evidence-class_method"></a>
Not documented.

### `legacy_project()` <a id="method-c-legacy_project"></a> <a id="legacy_project-class_method"></a>
Not documented.

### `normalize(value)` <a id="method-c-normalize"></a> <a id="normalize-class_method"></a>
Not documented.

### `prepend_load_paths(project)` <a id="method-c-prepend_load_paths"></a> <a id="prepend_load_paths-class_method"></a>
Not documented.

### `project_metadata(project, rails_metadata)` <a id="method-c-project_metadata"></a> <a id="project_metadata-class_method"></a>
Not documented.

### `project_metadata_for(payload)` <a id="method-c-project_metadata_for"></a> <a id="project_metadata_for-class_method"></a>
Not documented.

### `symbolize(value)` <a id="method-c-symbolize"></a> <a id="symbolize-class_method"></a>
Not documented.

### `write_completion(payload, result)` <a id="method-c-write_completion"></a> <a id="write_completion-class_method"></a>
Not documented.

### `write_failure(payload, code, details)` <a id="method-c-write_failure"></a> <a id="write_failure-class_method"></a>
Not documented.
