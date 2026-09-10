# jekyll-agent-markdown ternary-support follow-up

This follow-up reused `/private/tmp/branchproof-jekyll-trial` and `/private/tmp/branchproof-jekyll-trial-gems` after Branchproof’s ternary support and nested-child instrumentation fixes. The original gem checkout and production sources were not changed. The disposable targeted test remained outside the project `test/` tree, so this is the same 192-test suite as the prior full run.

Environment: Ruby 3.4.5, Bundler 4.0.19, Minitest 5.26.2, Jekyll 4.4.1, Rake 13.4.2, Prism 1.9.0, Branchproof 0.2.0, `LANG=en_US.UTF-8`, `LC_ALL=en_US.UTF-8`, real `HOME=/Users/luciang`, and the isolated gem home. Seed: `1234`.

Command:

```text
bundle exec mcdc analyze 'lib/**/*.rb' --project ruby --test 'test/**/*_test.rb' --format json --output tmp/branchproof-full-ternaries.json -- --seed 1234
```

The run passed: 192 tests, 1,155 assertions, 0 failures, 0 skips, and finalized evidence. Wall clock was approximately 32 seconds (`23:33:30` to `23:34:02` local time), indicative only and not a benchmark.

Artifact: `/private/tmp/branchproof-jekyll-trial/tmp/branchproof-full-ternaries.json`.

Branchproof now discovered 106 supported decisions and 120 eligible conditions. All six decisions previously reported as `unsupported_ternary` are now `SUPPORTED`; unsupported decisions and unsupported conditions both fell to zero. The run recorded 15,027 completed observations, 8 aborted observations, 1 unexecuted decision, 99 proven conditions, and 82.5% coverage (`99/120`).

The six formerly unsupported ternaries are:

- `lib/jekyll/agent_markdown/document_exporter.rb:87` — `source_kind == :post`.
- `lib/jekyll/agent_markdown/llms_text.rb:10` — `value`.
- `lib/jekyll/agent_markdown/metadata_footer.rb:22` — `content.end_with?("\n")`.
- `lib/jekyll/agent_markdown/llms_document_ordering.rb:36` — `comparison.zero?`.
- `lib/jekyll/agent_markdown/author_metadata.rb:14` — `author_name.empty?`.
- `lib/jekyll/agent_markdown/document_settings.rb:108` — `optional`.

Manual evidence checks found complete true/false observations for at least three of them:

- `document_exporter.rb:87` is proven by `[true] => true` in `test_exports_html_bare_and_root_permalinks_at_mapped_sibling_paths` and `[false] => false` in `test_traverses_collections_in_configured_order_after_pages`.
- `metadata_footer.rb:22` is proven by `[true] => true` in `test_exports_html_bare_and_root_permalinks_at_mapped_sibling_paths` and `[false] => false` in `test_appends_metadata_after_the_article_body`.
- `document_settings.rb:108` is proven by `[false] => false` in `test_normalizes_false_style_document_settings_as_an_opt_out` and `[true] => true` in `test_optional_documents_are_grouped_under_optional`.

The prior full run was 93/114 proven conditions (81.58%). With ternary support, the eligible denominator is 120 and the result is 99/120 (82.5%); the percentage is therefore not directly comparable without accounting for the six newly eligible conditions.
