# Ternary support implementation plan

> Execution: Luna implementation agents, with the root orchestrator owning
> integration, review, and verification. Continue on the current feature branch.

**Goal:** Include ordinary Ruby `condition ? left : right` predicates in the
same masking MC/DC analysis as supported `if` predicates.

**Architecture:** Use Prism's existing `IfNode` predicate ranges and the current
inline runtime frames. Observe the predicate's truth value, not the selected
branch's result. Do not introduce blocks, temporary local variables, or a
second execution of the predicate. Keep version 0.2.0 while it remains an
unpublished candidate; no new dependencies or schema/criterion version changes.

**Reference:** [Prism IfNode documentation](https://ruby.github.io/prism/rb/Prism/IfNode.html)
identifies ternaries by a missing `if_keyword_loc`.

## Contract

- Inventory ternaries with `context: "ternary"`, predicate-only byte ranges,
  deterministic identities, and the existing `&&`/`||` condition tree.
- Apply all existing predicate/file exclusions and condition limits. Removing
  `unsupported_ternary` does not make unsafe predicates eligible.
- Preserve selected branch, returned object identity, short-circuit order,
  assignments, local binding, exception/nonlocal control flow, source encoding,
  and line numbers.
- Record nested decisions exactly once when executed. An unchosen ternary
  branch must not execute or create observations.
- A ternary used inside another predicate is one atom in that outer predicate,
  while its own predicate remains a separately inventoried decision. Do not
  flatten branch results into the outer decision's Boolean expression tree.
- Count newly eligible conditions in the denominator. A lower percentage after
  expanding supported scope is not a regression in existing test evidence.

## Task 1: Inventory and semantic preservation

Files: `lib/branchproof/source.rb`, `lib/branchproof/instrumenter.rb`,
`test/test_source.rb`, `test/test_instrumenter.rb`.

- [x] Add source regressions before removing the exclusion. Inventory
  `value = first && second ? :yes : :no` and assert one supported ternary,
  two conditions, an `:and` tree, and predicate-only offsets. Include a
  parenthesized predicate, modifier `if` alongside a ternary, nested branches,
  and a ternary used as an outer `if` predicate.
- [x] Retain rejection tests for ambiguous multi-statement parentheses,
  keyword `and`/`or`, contextual syntax, and condition-limit overflow in
  ternary predicates. Ordinary ternaries must no longer emit
  `unsupported_ternary`.
- [x] Identify context in the existing `build_decision` conditional:

  ```ruby
  context = if node.is_a?(Prism::UnlessNode)
              "unless"
            elsif node.if_keyword_loc.nil?
              "ternary"
            else
              token = bytes.byteslice(node.if_keyword_loc.start_offset,
                                      node.if_keyword_loc.length)
              token == "elsif" ? "elsif" : "if"
            end
  ```

  Remove only the explicit `unsupported_ternary` reason; retain the other
  rejection and limit checks.
- [x] Compare original and rewritten execution for truthy/non-Boolean values,
  false/nil, branch object identity, side effects, assignments, branch raises,
  and `&&`/`||` short-circuiting. Use existing subprocess fixture helpers.
  For example, the second predicate and unused branch must not run here:

  ```ruby
  events = []
  value = (false && (events << :rhs)) ? (raise "unused") : :safe
  # value == :safe; events == []
  ```

- [x] Add at least three levels of nested predicates, e.g.
  `((a ? b : c) ? d : e) ? left : right`, and nested branch forms. Assert
  exact frame counts and balanced completion/abort events for executed
  decisions. If existing range traversal skips intermediate frames, repair
  the immediate-child selection: retain the outermost nested children in
  each range, then recursively render their descendants. Avoid a broader
  instrumentation refactor.
- [x] Run source and instrumenter tests with the explicit project Ruby;
  confirm the new supported-syntax tests fail before implementation and
  pass after it. Run scoped lint.

## Task 2: End-to-end Minitest evidence

File: `test/test_ternary_acceptance.rb` (dedicated acceptance coverage using
the existing CLI/subprocess fixture patterns).

- [x] Exercise `left && right ? false : true` with all required vectors.
  Assert that decision outcomes describe the predicate even though branch
  results are inverted, both conditions are proven, and owners identify the
  actual Minitest tests.
- [x] Exercise a ternary nested in a branch and a ternary inside an outer
  `if` predicate. Assert independent inventories, exact execution counts,
  no observations from unchosen branches, and complete evidence.
- [x] Exercise a raised predicate followed by a successful test execution.
  Confirm the aborted observation remains visible and runtime frames recover.
- [x] Verify terminal and JSON reporting, including no ternary exclusion
  diagnostics for ordinary supported predicates. Preserve explicit
  diagnostics for unsafe predicates.

## Task 3: Real-project confirmation and documentation

Files: `README.md`, `CHANGELOG.md`, `docs/releases/0.2.0.md`, and new
`docs/trials/agent-acl-ternaries.md` and
`docs/trials/jekyll-agent-markdown-ternaries.md`. Preserve the previous trial reports as
historical evidence of the narrower supported scope.

- [x] Reuse the disposable `agent-acl` and Jekyll trial projects and their
  dependency environments. Keep the originals untouched. Use seed 1234,
  UTF-8 locale, and the same original test selection (exclude trial-only
  targeted additions).
- [x] Require unchanged baseline counts: agent-acl 134 tests / 1,533
  assertions / 3 skips; Jekyll 192 tests / 1,155 assertions / no skips.
- [x] Check all 20 agent-acl and 6 Jekyll ordinary ternaries now enter
  supported inventory. Audit any newly unsupported predicate individually
  rather than asserting every syntactic ternary must be safe.
- [x] Record updated eligible/proven counts and inspect actual ternary
  vectors and owners. Never present an expanded denominator as lost coverage.
- [x] Document support for `?:`, remaining exclusions, and predicate outcome
  semantics. Update the candidate release verification counts after tests.

## Task 4: Review, package, and commits

- [x] Root reviews source semantics and acceptance evidence independently;
  Luna review checks nested range handling and unintended behavior changes.
- [x] Run the full Ruby 3.4.5 suite with Rails integration enabled, RuboCop,
  RBS validation, and the focused ternary suite on Ruby 3.3.6.
- [x] Rebuild the 0.2.0 gem and checksum; install in an isolated gem home.
  Run an installed-CLI ternary fixture and verify package contents and version
  metadata. No publication, tag, or push.
- [x] Commit implementation and trial/documentation evidence with Lore
  decision records. Mark this plan complete only after all required checks.

## Verification environment

Use explicit Ruby binaries and matching `PATH`; clear inherited gem paths for
core checks. Full Rails checks use the existing isolated gem home:

```sh
env GEM_HOME=/private/tmp/decisive-v2-ruby3.4-gemhome GEM_PATH=/private/tmp/decisive-v2-ruby3.4-gemhome:/Users/luciang/.gem/ruby/3.4.0:/Users/luciang/.rubies/ruby-3.4.5/lib/ruby/gems/3.4.0 BRANCHPROOF_RAILS_INTEGRATION=1 MT_NO_PLUGINS=1 RUBOCOP_CACHE_ROOT=/private/tmp/decisive-rubocop-cache PATH=/Users/luciang/.rubies/ruby-3.4.5/bin:/usr/bin:/bin /Users/luciang/.rubies/ruby-3.4.5/bin/ruby -S rake
```

Utility scripts must use Ruby's standard library and live in temporary
directories. Preserve the user's `HOME` and external repository worktrees.
