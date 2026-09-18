# frozen_string_literal: true

# rubocop:disable Style/StringLiterals, Style/RedundantReturn, Style/RedundantBegin

# EXC-15: Protected bodies ending in native nonlocal transfers
def example(mode)
  case mode
  when 'return'
    begin
      return :returned
    rescue StandardError
      :rescued
    end
  when 'break'
    [1].each do
      begin
        break :broken
      rescue StandardError
        :rescued
      end
    end
  when 'next'
    seen = []
    [1].each do |item|
      begin
        seen << item
        next
      rescue StandardError
        :rescued
      end
    end
    seen
  when "redo"
    attempts = 0
    [1].each do
      begin
        attempts += 1
        raise ArgumentError if attempts == 2

        redo
      rescue StandardError
        :rescued
      end
    end
    attempts
  end
end

# rubocop:enable Style/StringLiterals, Style/RedundantReturn, Style/RedundantBegin
