# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../lib/branchproof/collation_manifest"

class TestCollationManifest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("branchproof-manifest-")
    @manifest_path = File.join(@directory, "shards.json")
    @first_path = File.join(@directory, "unit.json")
    @second_path = File.join(@directory, "integration.json")
    @omitted_path = File.join(@directory, "omitted.json")
    File.write(@first_path, "first report")
    File.write(@second_path, "second report")
    File.write(@omitted_path, "must not be implicitly supplied")
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  def write_manifest(shards)
    File.write(@manifest_path, JSON.generate("shards" => shards))
  end

  def shard(id, report)
    { "id" => id, "report" => report }
  end

  def test_resolves_manifest_paths_and_maps_only_supplied_operands
    write_manifest([shard("unit", "unit.json"), shard("integration", "integration.json"),
                    shard("omitted", "omitted.json")])

    manifest = Dir.chdir(@directory) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: ["unit.json"])
    end

    assert_equal %w[unit integration omitted], manifest.expected_ids
    assert_equal [@first_path, @second_path, @omitted_path], manifest.declared_paths
    assert_equal [{ id: "unit", path: File.expand_path("unit.json", File.realpath(@directory)) }], manifest.inputs
  end

  def test_rejects_manifest_with_extra_fields_or_empty_shards
    [{ "shards" => [], "extra" => true }, { "shards" => [] }, { "shards" => "unit" }].each do |document|
      File.write(@manifest_path, JSON.generate(document))
      assert_raises(ArgumentError) do
        Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
      end
    end
  end

  def test_rejects_invalid_shard_shapes_and_empty_id_or_path
    [
      [{ "id" => "unit" }],
      [{ "id" => "unit", "report" => "unit.json", "extra" => true }],
      [shard("", "unit.json")],
      [shard("unit", "")],
      [shard(nil, "unit.json")]
    ].each do |shards|
      write_manifest(shards)
      assert_raises(ArgumentError) do
        Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
      end
    end
  end

  def test_rejects_duplicate_ids_and_normalized_paths
    [
      [shard("same", "unit.json"), shard("same", "integration.json")],
      [shard("unit", "unit.json"), shard("other", "./nested/../unit.json")]
    ].each do |shards|
      write_manifest(shards)
      assert_raises(ArgumentError) do
        Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
      end
    end
  end

  def test_rejects_symlink_and_hardlink_aliases_across_declared_ids
    symlink = File.join(@directory, "unit-link.json")
    File.symlink(@first_path, symlink)
    write_manifest([shard("unit", "unit.json"), shard("link", "unit-link.json")])
    assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
    end

    hardlink = File.join(@directory, "unit-hardlink.json")
    File.link(@first_path, hardlink)
    write_manifest([shard("unit", "unit.json"), shard("hardlink", "unit-hardlink.json")])
    assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
    end
  end

  def test_rejects_missing_paths_that_alias_through_a_symlinked_directory
    target_directory = File.join(@directory, "actual")
    FileUtils.mkdir_p(target_directory)
    File.symlink(target_directory, File.join(@directory, "alias"))
    write_manifest([shard("actual", "actual/missing.json"), shard("alias", "alias/missing.json")])

    assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
    end

    assert_equal Branchproof::CollationManifest.path_identity(File.join(target_directory, "missing.json")),
                 Branchproof::CollationManifest.path_identity(File.join(@directory, "alias/missing.json"))
  end

  def test_dangling_symlink_identity_matches_its_missing_target
    dangling_link = File.join(@directory, "pending.json")
    missing_target = File.join(@directory, "future.json")
    File.symlink("future.json", dangling_link)

    assert_equal Branchproof::CollationManifest.path_identity(missing_target),
                 Branchproof::CollationManifest.path_identity(dangling_link)
  end

  def test_rejects_duplicate_declarations_through_a_dangling_symlink
    File.symlink("future.json", File.join(@directory, "pending.json"))
    write_manifest([shard("pending", "pending.json"), shard("future", "future.json")])

    assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
    end
  end

  def test_path_identity_rejects_symlink_cycles
    first_link = File.join(@directory, "first.json")
    second_link = File.join(@directory, "second.json")
    File.symlink("second.json", first_link)
    File.symlink("first.json", second_link)

    assert_raises(ArgumentError) { Branchproof::CollationManifest.path_identity(first_link) }
  end

  def test_rejects_supplied_operands_not_declared_by_manifest
    write_manifest([shard("unit", "unit.json")])

    assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path, @second_path])
    end
  end

  def test_maps_operand_aliases_to_the_declared_id
    symlink = File.join(@directory, "unit-link.json")
    File.symlink(@first_path, symlink)
    write_manifest([shard("unit", "unit.json")])

    manifest = Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [symlink])
    assert_equal [{ id: "unit", path: symlink }], manifest.inputs

    manifest = Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path, symlink])
    assert_equal 2, manifest.inputs.length
    input_ids = manifest.inputs.map { |input| input.fetch(:id) }
    assert_equal %w[unit unit], input_ids
  end

  def test_whitespace_is_a_nonempty_id_and_report_path
    whitespace_path = File.join(@directory, " ")
    File.write(whitespace_path, "report")
    write_manifest([shard(" ", " ")])

    manifest = Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [whitespace_path])

    assert_equal [" "], manifest.expected_ids
    assert_equal [{ id: " ", path: whitespace_path }], manifest.inputs
  end

  def test_invalid_json_is_reported_as_an_argument_error
    File.write(@manifest_path, "{")

    error = assert_raises(ArgumentError) do
      Branchproof::CollationManifest.new(path: @manifest_path, supplied_paths: [@first_path])
    end

    assert_match(/invalid collation manifest JSON/, error.message)
  end
end
