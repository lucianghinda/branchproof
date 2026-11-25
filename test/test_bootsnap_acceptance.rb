# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestBootsnapAcceptance < Minitest::Test
  GEM_ROOT = File.expand_path("..", __dir__).freeze
  BRANCHPROOF = File.join(GEM_ROOT, "exe", "branchproof").freeze

  def test_compile_cache_delegates_unselected_files_and_preserves_branchproof_evidence
    version = ENV.fetch("BRANCHPROOF_BOOTSNAP_VERSION", nil)
    skip "set BRANCHPROOF_BOOTSNAP_VERSION to run the Bootsnap acceptance matrix" unless version

    assert_equal version, Gem.loaded_specs.fetch("bootsnap").version.to_s

    [false, true].each do |bundled|
      Dir.mktmpdir("branchproof-bootsnap-") do |root|
        write_fixture(root, version)
        mode = bundled ? "bundle exec" : "direct"
        output, error, status = Open3.capture3(run_environment(root, bundled), *command(bundled), chdir: root)
        assert status.success?, "#{mode} failed: #{error}\n#{output}"

        report = JSON.parse(output)
        assert_equal "PASSED", report.dig("baseline", "status"), error
        assert_equal 100.0, report.dig("analysis", "coverage", "mcdc", "percentage")
        assert_operator report.dig("observations", "vectors").length, :>=, 3
        refute_includes report.fetch("diagnostics").map { |item| item.fetch("code") }, "loader_conflict"

        events = File.readlines(File.join(root, "tmp", "bootsnap-events.log"), chomp: true)
        plain_path = File.realpath(File.join(root, "lib", "plain.rb"))
        access_path = File.realpath(File.join(root, "lib", "access.rb"))
        assert(events.any? { |event| event.include?(plain_path) },
               "Bootsnap did not receive the unselected Ruby file")
        refute(events.any? { |event| event.include?(access_path) },
               "Bootsnap handled the selected file before Branchproof")
        cache_files = Dir.glob(File.join(root, "tmp", "cache", "bootsnap", "compile-cache-iseq", "**", "*"))
                         .count { |path| File.file?(path) }
        assert_operator cache_files, :>, 0, "Bootsnap did not write ISeq compile-cache files"
      end
    end
  end

  private

  def write_fixture(root, version)
    FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "test"), File.join(root, "tmp")])
    File.write(File.join(root, "lib", "access.rb"), <<~RUBY)
      module Access
        def self.allowed?(paid, suspended)
          if paid && !suspended
            true
          else
            false
          end
        end
      end
    RUBY
    File.write(File.join(root, "lib", "plain.rb"), "PLAIN = true\n")
    File.write(File.join(root, "test", "access_test.rb"), <<~RUBY)
      gem "bootsnap", #{version.inspect}
      require "bootsnap"
      ENV.delete("DISABLE_BOOTSNAP")
      Bootsnap.instrumentation = ->(event, path) do
        File.open(ENV.fetch("BOOTSNAP_EVENTS"), "a") { |file| file.puts([event, path].join(" ")) }
      end
      Bootsnap.setup(cache_dir: "tmp/cache", load_path_cache: false, compile_cache_iseq: true,
                     compile_cache_yaml: false)
      require "plain"
      require "access"
      require "minitest/autorun"

      class AccessTest < Minitest::Test
        def test_access
          assert PLAIN
          assert Access.allowed?(true, false)
          refute Access.allowed?(false, false)
          refute Access.allowed?(true, true)
        end
      end
    RUBY
  end

  def command(bundled)
    args = [RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), BRANCHPROOF, "analyze", "lib/access.rb",
            "--test", "test/access_test.rb", "--project", "ruby", "--level", "3", "--format", "json",
            "--minimum", "mcdc=100"]
    return args unless bundled

    [RbConfig.ruby, File.join(File.dirname(RbConfig.ruby), "bundle"), "exec", *args]
  end

  def run_environment(root, bundled)
    environment = { "BOOTSNAP_EVENTS" => File.join(root, "tmp", "bootsnap-events.log"),
                    "BRANCHPROOF_BOOTSNAP_VERSION" => ENV.fetch("BRANCHPROOF_BOOTSNAP_VERSION"),
                    "DISABLE_BOOTSNAP" => nil,
                    "PATH" => [File.dirname(RbConfig.ruby), ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR) }
    environment["BUNDLE_GEMFILE"] = File.join(GEM_ROOT, "Gemfile") if bundled
    unless bundled
      ENV.keys.grep(/\ABUNDLE_/).each { |key| environment[key] = nil }
      environment["BUNDLE_GEMFILE"] = nil
      environment["RUBYOPT"] = nil
      gem_homes = Gem.path + Gem.loaded_specs.values.map { |spec| File.expand_path("../..", spec.full_gem_path) }
      environment["GEM_PATH"] = gem_homes.uniq.join(File::PATH_SEPARATOR)
    end
    environment
  end
end
