# Changed-coverage gates implementation plan

Use superpowers-ruby:subagent-driven-development with Luna implementers and
independent spec then quality reviews. One implementation writer at a time.

## Task 1: Changed-policy contract and integration

- [x] Add failing policy/CLI/saved-report tests for thresholds, config precedence,
  offline overrides, no-scope rejection, empty scope, incomplete/unsupported
  evidence, and independence from whole-run minima/display filters.
- [x] Implement changed policy using existing coverage counts; integrate CLI,
  configuration, Report, strict saved validation/schema 1.6, signatures, and
  shared terminal/GitHub/HTML gate output.
- [x] Run focused tests and lint; resolve Luna spec and quality findings.

## Task 2: Deterministic missing-evidence explanations

- [x] Add failing tests for the approved expression-based output, observed versus
  hypothetical vectors, short circuit/masking, and unavailable evidence.
- [x] Reuse analyzer candidates and shared rendering paths; escape output and
  clearly state hypothetical combinations may be infeasible.
- [x] Run focused tests and lint; resolve Luna spec and quality findings.

## Task 3: Acceptance, documentation, and delivery

- [x] Demonstrate passing tests plus a failing changed MC/DC gate, then a passing
  gate after adding the missing suspension case; verify offline parity and views.
- [x] Update README, CHANGELOG, and generate API docs.
- [x] Run full tests/lint, RBS validation, packaging checks, and fresh Luna review.
- [ ] Commit with Lore trailers, push, open a PR, verify all five CI jobs, and
  update the workspace roadmap with accurate delivery status.

Ruby commands use Ruby 4.0.1 and bundle exec. Utility scripts use Ruby standard
library in a temporary directory. No new dependencies.

## Local verification

- `bundle exec rake`: 1,849 tests, 244,012 assertions, zero failures/errors,
  13 optional integration skips; RuboCop checked 204 files without offenses.
  This includes the existing packaging and isolated installed-gem acceptance.
- A final `LIMIT_REACHED` wording regression was added while the full suite was
  running. The updated report tests passed separately: 37 tests, 253 assertions;
  report/test lint passed. Final CI will run the complete updated suite.
- RBS validation passed with a temporary `Rake::TaskLib` dependency stub.
- Independent Luna spec/quality reviews passed for both slices and the
  integrated diff. Spec reviews caught and corrected fractional comparison,
  help wording, and preservation of limit status beside candidate suggestions.
- A standalone temporary Git project reproduced the paid/suspended example:
  two passing tests yielded changed MC/DC 1/2 and exit 1 at an 80% threshold;
  the suspension test raised it to 2/2 and exit 0. Offline acceptance covered
  source removal, HTML/GitHub replay, display filtering, and policy tampering.
