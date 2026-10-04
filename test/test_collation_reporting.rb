# frozen_string_literal: true

require "test_helper"
require "branchproof/report"
require "stringio"
require_relative "support/summary_document"

class TestCollationReporting < Minitest::Test
  include SummaryDocument

  def collation_document(expected_shards: ["unit", "nightly:blue,1", "integration"], missing_shards: ["integration"],
                         collection_status: "incomplete")
    document = summary_document
    document[:collation] = {
      version: "1.0", collection_status: collection_status, expected_shards: expected_shards,
      missing_shards: missing_shards,
      shards: [
        { id: "unit", paths: ["artifacts/unit.json"] },
        { id: "nightly:blue,1", paths: ["artifacts/nightly|blue.json"] }
      ]
    }
    document
  end

  def render_terminal(document, view: :decisions)
    output = StringIO.new
    Branchproof::Report.from_document(document: document, view: view)
                       .write(io: output, format: :terminal)
    output.string
  end

  def test_terminal_views_show_collection_status_counts_missing_ids_and_contributors
    document = collation_document

    %i[decisions conditions tests decision_tables summary].each do |view|
      output = render_terminal(document, view: view)
      assert_includes output, "Collation: incomplete"
      assert_includes output, "Shards supplied: 2/3 expected"
      assert_includes output, "Missing shards: integration"
      assert_includes output, "unit: artifacts/unit.json"
      assert_includes output, "nightly:blue,1: artifacts/nightly|blue.json"
    end
  end

  def test_unknown_expected_count_is_reported_as_unknown
    output = render_terminal(collation_document(expected_shards: nil, missing_shards: [],
                                                collection_status: "unknown"))

    assert_includes output, "Collation: unknown"
    assert_includes output, "Shards supplied: 2 (expected count unknown)"
    assert_includes output, "Missing shards: none"
  end

  def test_terminal_escapes_control_characters_in_provenance
    document = collation_document
    document[:collation][:shards][0][:id] = "unit\ninjected"
    document[:collation][:shards][0][:paths] = ["artifacts/unit\r.json"]

    output = render_terminal(document)

    assert_includes output, "unit\\u{A}injected: artifacts/unit\\u{D}.json"
    refute_includes output, "unit\ninjected"
  end

  def test_github_annotations_and_step_summary_disclose_escaped_provenance
    document = collation_document
    document[:collation][:expected_shards] = ["unit", "nightly:blue,1", "escaped\nshard", "integration"]
    document[:collation][:shards] << {
      id: "escaped\nshard", paths: ["artifacts/escape|%report#{96.chr}json"]
    }
    report = Branchproof::Report.from_document(document: document)
    annotations = StringIO.new
    report.write(io: annotations, format: :github)

    assert_includes annotations.string, "::notice title=Branchproof collation"
    assert_includes annotations.string, "Collation: incomplete%0AShards supplied: 3/4 expected"
    assert_includes annotations.string, "nightly:blue,1: artifacts/nightly|blue.json"
    assert_includes annotations.string, "title=Branchproof collation%3A incomplete"
    assert_includes annotations.string, "escaped\\u{A}shard: artifacts/escape|%25report#{96.chr}json"

    markdown = report.step_summary
    assert_includes markdown, "Collation: incomplete"
    assert_includes markdown, "nightly:blue,1: artifacts/nightly\\|blue.json"
    assert_includes markdown, "escaped\\u{A}shard: artifacts/escape\\|%report"
    assert_includes markdown, "report#{96.chr}json"
    assert_includes markdown, "`unit: artifacts/unit.json`"
  end

  def test_html_discloses_and_escapes_collation_provenance
    document = collation_document
    document[:collation][:shards][0][:id] = "unit<script>"
    output = StringIO.new
    Branchproof::Report.from_document(document: document).write(io: output, format: :html)

    assert_includes output.string, "Collation provenance"
    assert_includes output.string, "unit&lt;script&gt;"
    refute_includes output.string, "unit<script>"
    assert_includes output.string, "artifacts/nightly|blue.json"
  end

  def test_reports_without_collation_keep_existing_terminal_output
    output = render_terminal(summary_document)

    refute_includes output, "Collation:"
    refute_includes output, "Contributing shards:"
  end
end
