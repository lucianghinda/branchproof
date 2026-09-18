# frozen_string_literal: true

module Branchproof
  # Source rewrite for value observations; it preserves the wrapped value.
  module ValueInstrumentation
    private

    def render_flow(bytes, decision, nested, encloses)
      return render_value(bytes, decision, nested, encloses) if decision.dig(:instrumentation, :type) == "value"

      super
    end

    # rubocop:disable-next Metrics/MethodLength -- success and exception traces differ.
    def render_value(bytes, decision, nested, encloses)
      expression = render_children(bytes, decision[:byte_start], decision[:byte_length], nested, encloses)
      metadata = decision.fetch(:instrumentation)
      runtime = self.class::RUNTIME
      id = decision.fetch(:id).inspect
      domain = metadata.fetch(:domain).inspect
      count = decision.fetch(:alternatives).length
      enter = "#{runtime}.enter(#{id}); #{runtime}.set_alternative_count(#{id}, #{count})"
      if metadata.fetch(:domain) == "dispatch"
        "(begin; #{enter}; begin; " \
          "(begin; #{runtime}.dispatch_path(#{id}, (#{expression}), false); end); " \
          "rescue ::Exception; #{runtime}.dispatch_path(#{id}, nil, true); raise; " \
          "ensure; #{runtime}.leave(#{id}); end; end)"
      else
        "(begin; #{enter}; begin; " \
          "#{runtime}.value_path(#{id}, (#{expression}), #{domain}); " \
          "ensure; #{runtime}.leave(#{id}); end; end)"
      end
    end
  end
end
