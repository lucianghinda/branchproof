# Module Branchproof::RailsSupport <a id="module-Branchproof-RailsSupport"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/branchproof/rails_support.rb |

Boots the selected Rails application after Branchproof's load hook is active.

## Constants
### `SUPPORTED_CAPYBARA_DRIVER` <a id="constant-SUPPORTED_CAPYBARA_DRIVER"></a> <a id="SUPPORTED_CAPYBARA_DRIVER-constant"></a>
Not documented.

### `SUPPORTED_RAILS` <a id="constant-SUPPORTED_RAILS"></a> <a id="SUPPORTED_RAILS-constant"></a>
Not documented.

### `SUPPORTED_RSPEC_RAILS_MAJOR` <a id="constant-SUPPORTED_RSPEC_RAILS_MAJOR"></a> <a id="SUPPORTED_RSPEC_RAILS_MAJOR-constant"></a>
Not documented.

## Public Class Methods
### `boot(project:)` <a id="method-c-boot"></a> <a id="boot-class_method"></a>
Boot the Rails application for the native Minitest adapter.

### `boot_environment(environment)` <a id="method-c-boot_environment"></a> <a id="boot_environment-class_method"></a>
Require the application and validate the process-wide Rails policy. This
method is public so adapter-specific helpers can own the remaining test
framework setup while sharing the exact same Rails boot checks.

### `environment_path(project)` <a id="method-c-environment_path"></a> <a id="environment_path-class_method"></a>
Not documented.

### `install_rspec_driver_guard!()` <a id="method-c-install_rspec_driver_guard-21"></a> <a id="install_rspec_driver_guard!-class_method"></a>
Not documented.

### `metadata()` <a id="method-c-metadata"></a> <a id="metadata-class_method"></a>
Not documented.

### `rails_application()` <a id="method-c-rails_application"></a> <a id="rails_application-class_method"></a>
- **@raise** [Error]

### `reloading_enabled?(config)` <a id="method-c-reloading_enabled-3F"></a> <a id="reloading_enabled?-class_method"></a>
- **@return** [Boolean]

### `rspec_rails_version()` <a id="method-c-rspec_rails_version"></a> <a id="rspec_rails_version-class_method"></a>
Not documented.

### `validate_application!()` <a id="method-c-validate_application-21"></a> <a id="validate_application!-class_method"></a>
- **@raise** [Error]

### `validate_rspec!(project:)` <a id="method-c-validate_rspec-21"></a> <a id="validate_rspec!-class_method"></a>
Validate the seam after an RSpec Rails helper has loaded. RSpec owns requiring
rspec/rails and configuring its example groups; this method only checks that
that setup is attached to the same, already-validated Rails application.
- **@raise** [Error]

### `validate_rspec_driver!(example_metadata)` <a id="method-c-validate_rspec_driver-21"></a> <a id="validate_rspec_driver!-class_method"></a>
RSpec Rails invokes this at example execution time, before the example can ask
Capybara to launch a browser. The adapter converts this explicit rejection
into an incomplete/error execution result.
- **@raise** [Error]

### `validate_test_environment()` <a id="method-c-validate_test_environment"></a> <a id="validate_test_environment-class_method"></a>
- **@raise** [Error]

### `validate_version_tuple!(rails_metadata)` <a id="method-c-validate_version_tuple-21"></a> <a id="validate_version_tuple!-class_method"></a>
- **@raise** [Error]
