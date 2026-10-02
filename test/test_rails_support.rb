# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "branchproof/rails_support"

class TestRailsSupport < Minitest::Test
  def test_rspec_rails_runtime_requires_ruby_4_or_newer
    metadata = { rails_version: "8.1.0", rspec_rails_version: "8.0.0" }
    %w[4.0.0 4.1.0].each do |version|
      assert Branchproof::RailsSupport.validate_version_tuple!(metadata.merge(ruby_version: version))
    end
    assert_raises(Branchproof::RailsSupport::Error) do
      Branchproof::RailsSupport.validate_version_tuple!(metadata.merge(ruby_version: "3.4.9"))
    end
  end

  def test_missing_environment_is_actionable
    Dir.mktmpdir do |root|
      error = assert_raises(Branchproof::RailsSupport::Error) do
        Branchproof::RailsSupport.boot(project: { root: root })
      end

      assert_includes error.message, "Rails project is missing"
      assert_includes error.message, "environment.rb"
    end
  end

  def test_uninitialized_application_is_rejected
    had_rails = Object.const_defined?(:Rails, false)
    previous = Object.const_get(:Rails, false) if had_rails
    fake_rails = Module.new do
      module_function

      def application
        Struct.new(:initialized?).new(false)
      end
    end
    Object.const_set(:Rails, fake_rails)

    error = assert_raises(Branchproof::RailsSupport::Error) do
      Branchproof::RailsSupport.send(:rails_application)
    end
    assert_includes error.message, "did not initialize"

    error = assert_raises(Branchproof::RailsSupport::Error) do
      Branchproof::RailsSupport.validate_rspec!(project: { kind: "rails", root: Dir.pwd })
    end
    assert_includes error.message, "did not initialize"
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails, false)
    Object.const_set(:Rails, previous) if had_rails
  end
end
