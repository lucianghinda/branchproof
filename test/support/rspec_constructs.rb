# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "ruby_constructs"

module RSpecConstructs
  ROOT = File.expand_path("../fixtures/ruby_constructs", __dir__).freeze
  GEM_ROOT = File.expand_path("../..", __dir__).freeze
  EXECUTABLE = File.join(GEM_ROOT, "exe", "branchproof").freeze
  MANIFESTS = RubyConstructs::MANIFESTS

  module_function

  def entries
    @entries ||= RubyConstructs.entries
  end

  def non_terminating_cases
    entries.sum { |entry| entry.fetch("cases").count { |sample| !sample.key?("exit") } }
  end

  def decision_count
    entries.sum { |entry| RubyConstructs.inventory(entry.fetch("id")).fetch(:decisions).length }
  end

  def decision_bearing_count
    entries.count { |entry| !RubyConstructs.inventory(entry.fetch("id")).fetch(:decisions).empty? }
  end

  def write_project(root, ids: entries.map { |entry| entry.fetch("id") }, spec_name: "corpus_spec.rb")
    FileUtils.mkdir_p(File.join(root, "lib", "corpus"))
    FileUtils.mkdir_p(File.join(root, "spec"))
    selected = entries.select { |entry| ids.include?(entry.fetch("id")) }
    selected.each do |entry|
      id = entry.fetch("id")
      FileUtils.cp(RubyConstructs.path(id), File.join(root, "lib", "corpus", "#{id.downcase.tr("-", "_")}.rb"))
    end
    File.write(File.join(root, "spec", spec_name), spec_source(root, selected))
    File.write(File.join(root, ".rspec"), "--format progress\n")
    root
  end

  def spec_source(root, selected)
    cases = selected.flat_map do |entry|
      entry.fetch("cases").reject { |sample| sample.key?("exit") }.map { |sample| [entry, sample] }
    end
    body = cases.map { |entry, sample| example_source(root, entry, sample) }.join("\n")
    <<~RUBY
      # frozen_string_literal: true
      require "json"
      require "rspec/expectations"

      RSpec.describe "Branchproof native Ruby construct corpus" do
      #{body}
      end
    RUBY
  end

  def example_source(root, entry, sample)
    id = entry.fetch("id")
    path = File.join(root, "lib", "corpus", "#{id.downcase.tr("-", "_")}.rb")
    expected = sample.slice("result", "error")
    args_json = JSON.generate(sample.fetch("args", []))
    kwargs_json = JSON.generate(sample.fetch("kwargs", {}))
    call = "-> { scope = Module.new; load(#{path.inspect}, scope); receiver = Object.new.extend(scope); args = JSON.parse(#{args_json.inspect}); kwargs = JSON.parse(#{kwargs_json.inspect}); receiver.send(:example, *args, **kwargs.transform_keys(&:to_sym)) }"
    assertion = if sample.key?("error")
                  "expect(&call).to raise_error(Object.const_get(#{sample.fetch("error").inspect}))"
                elsif sample.fetch("result").nil?
                  "expect(JSON.parse(JSON.generate(call.call))).to be_nil"
                else
                  "expect(JSON.parse(JSON.generate(call.call))).to eq(#{expected.fetch("result").inspect})"
                end
    <<~RUBY
      it(#{"#{id}: #{sample.fetch("name")}".inspect}) do
        call = #{call}
        #{assertion}
      end
    RUBY
  end
end
