# Framework-independent installation

Branchproof consumers should install only the test framework they use. Remove
Minitest from the gem's runtime dependencies while keeping it in the development
bundle. Prism remains a runtime dependency; do not add dependencies or change the
gem version, coverage semantics, report schemas or framework auto-detection.

## Adapter contract

Load a framework only when its adapter is selected. Before Minitest lifecycle
hooks or application/test boot, verify that Minitest is available and satisfies
the existing `>= 5.25.5, < 6` requirement. Missing Minitest must yield a structured,
actionable `minitest_missing` diagnostic explaining the application bundle entry.
An unsupported version must yield `minitest_unsupported_version`, naming the
detected version and supported range. The CLI exits 2 and preserves incomplete
evidence for both cases. Do not claim Minitest 6 support.

Use the activated gem specification's version when available, matching the old
gemspec constraint; fall back to Minitest::VERSION only for a non-RubyGems load.
Inspection found package version 5.27.0 with runtime constant 5.26.2, so assuming
those version sources always agree would not preserve the installation contract.
Report metadata uses that same package version, with the same constant fallback.
Evidence merges preserve incoming analysis incompleteness so the CLI cannot
turn a failed adapter startup back into a complete analysis snapshot.

Catch only LoadError for the framework's own requested entry points. An unrelated
dependency's LoadError must not be relabeled as a missing test framework. Keep
RSpec's existing missing-framework behavior intact. Use one small shared loading
and validation path if Worker and the public Minitest adapter both need it, and
follow existing diagnostic conventions rather than adding a framework registry.

## Consumer contract

Use the actual built gem in temporary consumer environments. An RSpec-only
consumer can analyze and produce valid attributed evidence while Minitest is
unavailable and unloaded. A Minitest-only consumer can do the same without RSpec.
A consumer with neither framework can load Branchproof, render saved terminal,
JSON and HTML reports, and compare saved reports without trying to load adapters.
The selected missing adapter produces the documented error instead of a success
or unexplained worker-incomplete result.

Tests must clear inherited Bundler/load-path settings and demonstrate the absent
framework is not discoverable. Reuse already-installed locked dependencies or
cached gem archives without network access; no runtime dependency installation
inside normal application code. Keep consumer setup bounded and deterministic.

## Documentation and scope

Document application-owned Minitest/RSpec dependencies and current version support.
Keep the repository's Minitest development dependency and update its lockfile only
for the removed package dependency. Refresh generated documentation. Reconcile
the workspace roadmap's delivered changed-scope and HTML tasks and mark this
specific Task 9 slice complete after verification; doctor, Minitest 6, SimpleCov
and support-matrix expansion remain future work.

## Decisions

- Framework choice belongs to the consuming application, not the core gemspec.
- Runtime validation preserves the previous dependency range after making the
  framework optional, and makes setup failures actionable.
- Packaged consumer isolation is the acceptance criterion; stubbing `require`
  alone cannot prove installation independence.
- This increment does not add doctor or widen framework support.
