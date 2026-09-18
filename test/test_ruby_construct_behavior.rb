# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_constructs"

class TestRubyConstructBehavior < Minitest::Test
  RubyConstructs.entries.each do |fixture|
    id = fixture.fetch("id")
    fixture.fetch("cases").each_with_index do |sample, index|
      define_method("test_#{id}_#{index}_#{sample.fetch("name")}") do
        actual = RubyConstructs.capture(id, sample)
        expected = sample.slice("result", "error")
        if sample.key?("exit")
          assert_equal sample.fetch("exit"), actual[:exitstatus], id
          assert_equal sample.fetch("stdout", ""), actual[:stdout], id
          assert_equal sample.fetch("stderr", ""), actual[:stderr], id
        else
          assert_equal 0, actual[:exitstatus], actual.inspect
          assert_equal expected, actual[:result], actual.inspect
          assert_equal sample.fetch("stdout", ""), actual[:stdout], actual.inspect
          assert_equal sample.fetch("stderr", ""), actual[:stderr], actual.inspect
        end
        assert_kind_of Hash, actual[:executions], actual.inspect
        assert_kind_of Array, actual[:executions][:vectors], actual.inspect unless sample.key?("exit")
        assert_equal RubyConstructs.inventory(id).fetch(:diagnostics), actual[:diagnostics], actual.inspect
      end
    end
  end

  %w[basic patterns flow predicates].each do |manifest|
    define_method("test_document_#{manifest}_has_valid_analysis") do
      ids = RubyConstructs.entries.select do |entry|
        manifest_prefix(manifest).any? { |prefix| entry.fetch("id").start_with?(prefix) }
      end
      ids.each do |fixture|
        document = RubyConstructs.document(fixture.fetch("id"))
        expected_complete = fixture.fetch("cases").none? { |sample| sample.key?("exit") }
        assert_equal expected_complete, document.fetch(:evidence).fetch(:completeness).fetch(:observation), fixture.fetch("id")
        assert_equal true, document.fetch(:analysis).fetch(:completeness).fetch(:analysis)
      end
    end
  end

  def test_capture_uses_stable_owners_and_returns_isolated_copies
    sample = RubyConstructs.entry("VAL-01").fetch("cases").first
    first = RubyConstructs.capture("VAL-01", sample)
    owner = first.fetch(:executions).fetch(:tests).first.fetch(:id)
    assert_equal "RubyConstructs#VAL-01/literal truthiness", owner
    first.fetch(:executions).fetch(:tests).clear
    second = RubyConstructs.capture("VAL-01", sample)
    assert_equal([owner], second.fetch(:executions).fetch(:tests).map { |test| test.fetch(:id) })
  end

  def test_exit_case_document_is_marked_incomplete_without_fabricated_vectors
    document = RubyConstructs.document("FLOW-12")
    refute document.fetch(:evidence).fetch(:completeness).fetch(:observation)
    assert document.fetch(:evidence).fetch(:vectors).any?
    immediate = RubyConstructs.entry("FLOW-12").fetch("cases").find { |sample| sample.fetch("args") == ["immediate"] }
    assert_empty RubyConstructs.capture("FLOW-12", immediate).fetch(:executions)
    immediate_document = RubyConstructs.document("FLOW-12", cases: [immediate])
    assert_empty immediate_document.fetch(:evidence).fetch(:vectors)
    refute immediate_document.fetch(:evidence).fetch(:completeness).fetch(:observation)
  end

  def test_malformed_child_evidence_is_not_treated_as_missing
    Tempfile.create("branchproof-invalid-evidence") do |file|
      file.write("{invalid")
      file.flush
      assert_raises(JSON::ParserError) { RubyConstructs.read_json(file.path) }
    end
  end

  def test_timeout_terminates_and_reaps_only_the_fixture_child
    Dir.mktmpdir("branchproof-construct-timeout") do |directory|
      source_path = File.join(directory, "fixture.rb")
      inventory_path = File.join(directory, "inventory.json")
      pid_path = File.join(directory, "pid")
      File.write(source_path, "def example(pid_path); File.write(pid_path, Process.pid); sleep; end\n")
      File.write(inventory_path, JSON.generate(RubyConstructs.inventory("ARG-01")))

      error = assert_raises(Timeout::Error) do
        RubyConstructs.run_child(source_path, inventory_path, { "args" => [pid_path] },
                                 File.join(directory, "result.json"), File.join(directory, "evidence.json"),
                                 owner: "timeout-regression", timeout: 2)
      end
      assert_includes error.message, "timeout-regression"
      pid = Integer(File.read(pid_path))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    end
  end

  private

  def manifest_prefix(name)
    { "basic" => %w[VAL IF LOG CASE NIL ASGN ARG], "patterns" => %w[PAT],
      "flow" => %w[LOOP FLIP EXC FLOW], "predicates" => %w[PRED API] }.fetch(name)
  end
end
