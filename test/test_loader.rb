# frozen_string_literal: true

require "test_helper"
require "branchproof/loader"
require "branchproof/source"
require "branchproof/limits"
require "branchproof/evidence"
require "branchproof/runtime"
require "branchproof/instrumenter"
require "tmpdir"
require "open3"
require "rbconfig"

class TestLoader < Minitest::Test
  InstrumenterStub = Struct.new(:result) do
    def rewrite(unit:)
      result || { bytes: unit[:original_bytes], changed: false, diagnostics: [] }
    end
  end

  def test_install_registers_a_process_local_cruby_hook
    loader = Branchproof::Loader.new(inventory: { source_units: [] }, instrumenter: InstrumenterStub.new)
    @installed_loader = loader

    status = loader.install

    assert_equal "installed", status[:status]
  end

  def test_second_loader_rejects_existing_hook_without_replacing_owner
    first = Branchproof::Loader.new(inventory: { source_units: [] }, instrumenter: InstrumenterStub.new)
    second = Branchproof::Loader.new(inventory: { source_units: [] }, instrumenter: InstrumenterStub.new)
    @installed_loader = first
    assert_equal "installed", first.install[:status]
    original_owner = RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner)

    status = second.install

    assert_equal "rejected", status[:status]
    assert_equal "loader_conflict", status[:reason]
    assert_same original_owner, RubyVM::InstructionSequence.instance_variable_get(:@branchproof_load_iseq_owner)
  end

  def test_load_iseq_returns_nil_for_unselected_path
    loader = Branchproof::Loader.new(
      inventory: { source_units: [{ absolute_path: "/tmp/selected.rb", original_bytes: "true\n" }] },
      instrumenter: InstrumenterStub.new
    )

    assert_nil loader.load_iseq("/tmp/other.rb")
  end

  def test_selected_source_compiles_with_original_filename_and_line
    Dir.mktmpdir("branchproof-selected") do |directory|
      path = File.join(directory, "é.rb")
      bytes = "# encoding: UTF-8\nVALUE = :ok\n"
      File.binwrite(path, bytes)
      loader = Branchproof::Loader.new(
        inventory: { source_units: [{ absolute_path: path, real_path: File.realpath(path), original_bytes: bytes }] },
        instrumenter: InstrumenterStub.new({ bytes: bytes, changed: true, diagnostics: [] })
      )
      @installed_loader = loader
      assert_equal "installed", loader.install[:status]

      iseq = RubyVM::InstructionSequence.load_iseq(path)

      refute_nil iseq
      assert_equal File.realpath(path), iseq.path
      assert_equal :ok, iseq.eval
    end
  end

  def test_loader_rejects_a_preloaded_selected_file
    $LOADED_FEATURES << "/tmp/selected.rb" unless $LOADED_FEATURES.include?("/tmp/selected.rb")
    loader = Branchproof::Loader.new(
      inventory: { source_units: [{ absolute_path: "/tmp/selected.rb", original_bytes: "true\n" }] },
      instrumenter: InstrumenterStub.new
    )

    status = loader.install

    assert_equal "rejected", status[:status]
    assert_equal "preloaded_target", status[:reason]
  ensure
    $LOADED_FEATURES.delete("/tmp/selected.rb")
  end

  def test_loader_is_active_while_native_require_keeps_caching_and_retry_semantics
    # Fixture files communicate through globals because they are loaded by Kernel.require.
    # rubocop:disable Style/GlobalVars
    Dir.mktmpdir("branchproof-loader") do |directory|
      suffix = Process.pid.to_s
      child_name = "branchproof_child_#{suffix}"
      parent_name = "branchproof_parent_#{suffix}"
      retry_name = "branchproof_retry_#{suffix}"
      probe_name = "branchproof_probe_#{suffix}"
      parent_path = File.join(directory, "#{parent_name}.rb")
      child_path = File.join(directory, "#{child_name}.rb")
      retry_path = File.join(directory, "#{retry_name}.rb")
      File.write(child_path, "$events << :child\n")
      File.write(parent_path, "require_relative '#{child_name}'\nif true\n  $events << :parent\nend\n")
      File.write(retry_path, "$attempts += 1\nraise 'first' if $attempts == 1\nif true\n  $events << :retry\nend\n")
      probe_path = File.join(directory, "#{probe_name}.rb")
      File.write(probe_path, "$events << :probe_before\nif $events.include?(:parent)\n  $events << :probe_true\nend\n")
      inventory = Branchproof::Source.new(root: directory, limits: Branchproof::Limits.default).inventory(
        paths: [probe_path, parent_path, child_path, retry_path]
      )
      evidence = Branchproof::Evidence.new(inventory: inventory, limits: Branchproof::Limits.default, run_id: "loader-run")
      Branchproof::Runtime.boot(evidence: evidence)
      loader = Branchproof::Loader.new(inventory: inventory, instrumenter: Branchproof::Instrumenter.new)
      @installed_loader = loader
      assert_equal "installed", loader.install[:status]
      $LOAD_PATH.unshift(directory)
      $events = []
      # Requiring twice is the behavior under test: native feature caching.
      require parent_name
      # rubocop:disable Lint/DuplicateRequire
      require parent_name
      # rubocop:enable Lint/DuplicateRequire
      $attempts = 0
      begin
        require retry_name
      rescue RuntimeError => e
        assert_equal "first", e.message
      end
      require retry_name
      require probe_name
      snapshot = evidence.snapshot
      assert_equal %i[child parent retry probe_before probe_true], $events
      assert_equal 2, $attempts
      assert(%W[#{child_name}.rb #{parent_name}.rb #{retry_name}.rb].all? do |name|
        $LOADED_FEATURES.include?(File.realpath(File.join(directory, name)))
      end)
      assert_operator snapshot[:vectors].length, :>=, 3
      assert_equal 0, snapshot[:abort_counts].values.sum
    ensure
      $LOAD_PATH.delete(directory)
      $LOADED_FEATURES.delete_if { |feature| feature.start_with?(directory) }
    end
    # rubocop:enable Style/GlobalVars
  end

  def test_diagnostics_report_a_hook_replaced_after_installation
    loader = Branchproof::Loader.new(inventory: { source_units: [] }, instrumenter: InstrumenterStub.new)
    assert_equal "installed", loader.install[:status]
    RubyVM::InstructionSequence.singleton_class.send(:remove_method, :load_iseq)

    diagnostic = loader.diagnostics.last

    assert_equal "loader_conflict", diagnostic[:code]
    assert_equal "error", diagnostic[:severity]
  ensure
    if RubyVM::InstructionSequence.instance_variable_defined?(:@branchproof_load_iseq_owner)
      RubyVM::InstructionSequence.remove_instance_variable(:@branchproof_load_iseq_owner)
    end
  end

  def teardown
    if @installed_loader && RubyVM::InstructionSequence.respond_to?(:load_iseq)
      RubyVM::InstructionSequence.singleton_class.send(:remove_method, :load_iseq)
    end
    if RubyVM::InstructionSequence.instance_variable_defined?(:@branchproof_load_iseq_owner)
      RubyVM::InstructionSequence.remove_instance_variable(:@branchproof_load_iseq_owner)
    end
  rescue NameError
    nil
  end
end
