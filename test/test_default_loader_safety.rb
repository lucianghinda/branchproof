# frozen_string_literal: true

require "test_helper"
require "branchproof/loader"
require "tmpdir"

class TestDefaultLoaderSafety < Minitest::Test
  def test_loader_converts_rewrite_exception_to_diagnostic
    Dir.mktmpdir("branchproof-loader-default") do |directory|
      path = File.join(directory, "fixture.rb")
      bytes = "VALUE = 1\n"
      File.write(path, bytes)
      inventory = {
        source_units: [{ absolute_path: path, real_path: File.realpath(path), original_bytes: bytes,
                         source_id: "source" }]
      }
      instrumenter = Object.new
      instrumenter.define_singleton_method(:rewrite) { |**| raise NoMethodError, "parameter shape" }
      loader = Branchproof::Loader.new(inventory: inventory, instrumenter: instrumenter)
      loader.instance_variable_set(:@installed, true)

      assert_nil loader.load_iseq(path)
      # `diagnostics` also checks process-wide hook ownership. This unit test
      # exercises load_iseq directly, so inspect the recorded rewrite failure
      # without requiring a process-global hook installation.
      diagnostic = loader.instance_variable_get(:@diagnostics).last
      assert_equal "rewrite_failure", diagnostic[:code]
      assert_equal "error", diagnostic[:severity]
      assert_includes diagnostic[:message], "parameter shape"
    end
  end
end
