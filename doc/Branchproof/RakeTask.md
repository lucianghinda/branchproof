# Class Branchproof::RakeTask <a id="class-Branchproof-RakeTask"></a>

|  |  |
| --- | --- |
| **Inherits** | Rake::TaskLib |
| **Defined in** | lib/branchproof/rake_task.rb |

Defines a Rake task that runs `branchproof analyze` in a subprocess.

The task shells out to the `branchproof` executable, so the isolated worker
model is unchanged. Only options the Rakefile sets are passed as CLI flags.
Everything else keeps the CLI default, and <code>.branchproof.json</code>
precedence stays intact.

**@example Minitest project**
```ruby
require "branchproof/rake_task"

Branchproof::RakeTask.new(:branchproof) do |t|
  t.sources = ["lib/**/*.rb"]
  t.tests = ["test/**/*_test.rb"]
end
```

**@example RSpec project with a coverage gate**
```ruby
Branchproof::RakeTask.new(:branchproof) do |t|
  t.sources = ["app/**/*.rb"]
  t.framework = "rspec"
  t.minimum = ["mcdc=100"]
end
```

## Constants
### `DEFAULTS` <a id="constant-DEFAULTS"></a> <a id="DEFAULTS-constant"></a>
CLI defaults. The task only passes a flag when the Rakefile sets it.

### `OPTIONS` <a id="constant-OPTIONS"></a> <a id="OPTIONS-constant"></a>
Option names in the order they appear in the built argv.

### `REPEATED_FLAGS` <a id="constant-REPEATED_FLAGS"></a> <a id="REPEATED_FLAGS-constant"></a>
Options that repeat one flag per array item.

## Attributes
### `description` [RW] <a id="attribute-i-description"></a> <a id="description-instance_method"></a>
- **@return** [String] the task description shown by `rake -T`

### `format` [R] <a id="attribute-i-format"></a> <a id="format-instance_method"></a>
Output format: `"terminal"` or `"json"`.
- **@return** [String]

### `framework` [R] <a id="attribute-i-framework"></a> <a id="framework-instance_method"></a>
Test framework: `"auto"`, `"minitest"`, or `"rspec"`.
- **@return** [String]

### `level` [R] <a id="attribute-i-level"></a> <a id="level-instance_method"></a>
Report level: 1, 2, or 3.
- **@return** [Integer]

### `minimum` [R] <a id="attribute-i-minimum"></a> <a id="minimum-instance_method"></a>
Coverage gates as `"criterion=threshold"` strings, one <code>--minimum</code>
flag each.
- **@return** [Array<String>]

### `missing_only` [R] <a id="attribute-i-missing_only"></a> <a id="missing_only-instance_method"></a>
When true, terminal output lists only missing evidence.
- **@return** [Boolean]

### `name` [R] <a id="attribute-i-name"></a> <a id="name-instance_method"></a>
- **@return** [Symbol] the Rake task name

### `output` [R] <a id="attribute-i-output"></a> <a id="output-instance_method"></a>
Output path, or nil to write to stdout.
- **@return** [String, nil]

### `project` [R] <a id="attribute-i-project"></a> <a id="project-instance_method"></a>
Project mode: `"auto"`, `"ruby"`, or `"rails"`.
- **@return** [String]

### `runner_args` [RW] <a id="attribute-i-runner_args"></a> <a id="runner_args-instance_method"></a>
Extra arguments appended after <code>--</code> and passed to the test runner.
- **@return** [Array<String>]

### `sources` [RW] <a id="attribute-i-sources"></a> <a id="sources-instance_method"></a>
Source globs passed as positional arguments.
- **@return** [Array<String>]

### `tests` [R] <a id="attribute-i-tests"></a> <a id="tests-instance_method"></a>
Test globs, one <code>--test</code> flag each.
- **@return** [Array<String>]

### `view` [R] <a id="attribute-i-view"></a> <a id="view-instance_method"></a>
Terminal view: `"decisions"`, `"conditions"`, `"tests"`, or
`"decision-tables"`.
- **@return** [String]

## Public Instance Methods
### `argv()` <a id="method-i-argv"></a> <a id="argv-instance_method"></a>
Builds the CLI arguments without running anything.
- **@return** [Array<String>] arguments for `branchproof analyze`

### `command()` <a id="method-i-command"></a> <a id="command-instance_method"></a>
Full command line, starting with the current Ruby and the gem executable.
- **@return** [Array<String>]

### `executable()` <a id="method-i-executable"></a> <a id="executable-instance_method"></a>
Path to the `branchproof` executable. Works inside this repository and as an
installed gem.
- **@return** [String]

### `initialize(name = :branchproof)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
Defines the task. The block receives the task so a Rakefile can set options.
- **@param** `name` [Symbol, String] the Rake task name
- **@return** [RakeTask] a new instance of RakeTask
- **@yieldparam** `task` [RakeTask] this task, before it is defined

### `run()` <a id="method-i-run"></a> <a id="run-instance_method"></a>
Runs the analysis in a subprocess. A non-zero exit status ends the Rake
process with the same status so CI fails on coverage gate failures.
- **@raise** [Error]
- **@return** [void]
