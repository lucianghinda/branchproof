# frozen_string_literal: true

require "json"
require "test_helper"
require "tmpdir"
require "fileutils"

class TestConfiguration < Minitest::Test
  def test_loads_a_project_configuration_and_resolves_patterns_from_project_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      path = File.join(root, "config", "policy.json")
      File.write(path, JSON.generate(
                         schema_version: 1,
                         project: "rails",
                         framework: "rspec",
                         sources: ["app/**/*.rb"],
                         tests: ["spec/**/*_spec.rb"],
                         exclude: ["app/generated/**/*.rb"],
                         minimum: { mcdc: 80 }
                       ))

      config = Branchproof::Configuration.load(path: path, root: root, explicit: true)

      assert_equal 1, config.fetch(:schema_version)
      assert_equal "rails", config.fetch(:project)
      assert_equal "rspec", config.fetch(:framework)
      assert_equal ["app/**/*.rb"], config.fetch(:sources)
      assert_equal ["spec/**/*_spec.rb"], config.fetch(:tests)
      assert_equal ["app/generated/**/*.rb"], config.fetch(:exclude)
      assert_equal({ "mcdc" => 80 }, config.fetch(:minimum))
      assert_equal path, config.fetch(:path)
      assert_equal root, config.fetch(:root)
    end
  end

  def test_missing_default_configuration_is_absent_but_missing_explicit_configuration_is_an_error
    Dir.mktmpdir do |root|
      assert_nil Branchproof::Configuration.load(path: File.join(root, ".branchproof.json"), root: root)

      error = assert_raises(ArgumentError) do
        Branchproof::Configuration.load(path: File.join(root, "missing.json"), root: root, explicit: true)
      end
      assert_includes error.message, "configuration file does not exist"
    end
  end

  def test_disabled_configuration_does_not_require_a_file
    Dir.mktmpdir do |root|
      assert_nil Branchproof::Configuration.load(path: File.join(root, ".branchproof.json"), root: root,
                                                 disabled: true)
    end
  end

  def test_rejects_unknown_fields_bad_types_invalid_schema_and_invalid_minimums
    cases = [
      { schema_version: 1, unknown: true },
      { schema_version: "1" },
      { schema_version: 1.0 },
      { schema_version: 1, sources: [] },
      { schema_version: 1, tests: [""] },
      { schema_version: 1, exclude: [""] },
      { schema_version: 1, exclude: [1] },
      { schema_version: 1, minimum: { mcdc: 101 } },
      { schema_version: 1, minimum: { mcdc: "80" } },
      { schema_version: 1, minimum: { other: 80 } }
    ]

    Dir.mktmpdir do |root|
      cases.each_with_index do |payload, index|
        path = File.join(root, "config-#{index}.json")
        File.write(path, JSON.generate(payload))
        error = assert_raises(ArgumentError) do
          Branchproof::Configuration.load(path: path, root: root, explicit: true)
        end
        refute_empty error.message
      end
    end
  end

  def test_rejects_malformed_json_before_a_worker_can_run
    Dir.mktmpdir do |root|
      path = File.join(root, ".branchproof.json")
      File.write(path, "{not json")

      error = assert_raises(ArgumentError) do
        Branchproof::Configuration.load(path: path, root: root)
      end
      assert_includes error.message, "invalid JSON configuration"
    end
  end
end
