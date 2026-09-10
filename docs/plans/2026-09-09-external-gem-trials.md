# Branchproof external gem trials

Status: the two owner-selected gem trials passed with separate Luna agents.

Selected targets:

- `/Users/luciang/Dropbox/workprojects/opensource/agent-acl/gems/agent-acl`
- `/Users/luciang/Dropbox/workprojects/opensource/jekyll-plugins/jekyll-agent-markdown`

Trials use disposable copies and record findings under `docs/trials/`. A Rails
application has not been selected; that follow-up is outside these two trials.

## Results

- [agent-acl trial](../trials/agent-acl.md): matching full runs of 134 tests,
  1,533 assertions, and 3 skips; 28 of 165 eligible conditions proven.
- [jekyll-agent-markdown trial](../trials/jekyll-agent-markdown.md): matching
  full runs of 192 tests without skips; 93 of 114 eligible conditions proven.
- Targeted tests in disposable copies increased the narrow proof counts in
  both projects. Original checkouts remain unchanged.
- Found and fixed stale embedded evidence version metadata in Branchproof;
  rebuilt and verified the local package. Source syntax exclusions and
  unexecuted decisions remain visible rather than counted as proven.

These results validate the tested versions and selected source scope. They
do not establish universal gem compatibility or include a new external Rails
application trial.

## Objective

Validate the 0.2.0 Apache-2.0 candidate against existing Minitest projects
before publication. The orchestrator owns scope, review, and final evidence;
Luna agents perform the trials and implement any fixes.

## Target selection

Start with two plain Ruby gems: one small suite with straightforward loading,
and one with compound conditions and more substantial test setup. Then add
one Rails application using Minitest. Record each repository path, revision,
Ruby version, Minitest version, and normal test command before assigning work.
Do not assume a project uses Minitest from its directory name.

## Trial sequence

1. Create a disposable checkout of the selected revision. Keep the owner's
   working files intact. Inspect project instructions and test configuration.
   Run its normal suite and record test counts, assertions, skips, failures,
   elapsed time, seed, and relevant environment settings.
2. Add the local Branchproof candidate to the disposable project's bundle.
   Record dependency resolution changes. Start with one source file containing
   meaningful decisions and the tests that exercise it. Use an explicit
   `--project ruby` selection and the same seed as the comparable baseline.
3. Compare the selected tests with an uninstrumented run of the same files
   and runner arguments. Confirm counts and outcomes match. Save the JSON
   report separately from test output, together with commands and exit codes.
4. Manually audit at least three supported decisions, including a compound
   condition and short-circuit evaluation where available. Check source
   locations, observed values, test ownership, witnesses, and missing evidence.
   Add a deliberately missing case only in the disposable checkout and verify
   that the relevant evidence changes without hiding other gaps.
5. Expand to the full discoverable suite. Record wall-clock overhead relative
   to the equivalent serial baseline. Repeat timing runs if needed to distinguish
   overhead from normal variation; do not call a noisy single run a benchmark.
6. For Rails, repeat with `--project rails`, the application bundle, and a
   serial test baseline. Verify test environment selection, lazy/eager loading,
   and honest diagnostics for unsupported configuration.
7. Reduce each unexpected failure to a regression fixture in Branchproof.
   Assign fixes to Luna with explicit file ownership; review and verify fixes
   before committing. Re-run the affected external case after each fix.

Example narrow run from a disposable Ruby project's root (replace paths with
the actual selected source and test):

```sh
bundle exec mcdc analyze lib/example.rb --project ruby --test test/example_test.rb --format json --output tmp/branchproof.json -- --seed 1234
```

## Acceptance and release decision

- Selected test counts and outcomes match the comparable baseline.
- Manually checked decisions agree with the reported evidence.
- Unsupported syntax, failed tests, and truncated analysis cannot appear as
  complete passing coverage.
- Both plain Ruby trials pass; Rails results identify the tested versions and
  any limitations explicitly.
- Compatibility fixes pass Branchproof's suite, lint, signature validation,
  and installed-package checks.

Record results per project in a follow-up report: revision, environment,
commands, baseline and instrumented results, manual evidence checks, timing,
diagnostics, fixes, and unresolved limitations. Keep third-party source code
and sensitive test output out of committed reports. Do not publish the gem
as part of these trials.
