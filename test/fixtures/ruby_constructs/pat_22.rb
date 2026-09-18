# frozen_string_literal: true

# PAT-22: Nested hash and array pattern
def example(value)
  users = value["users"]&.map { |user| user.transform_keys(&:to_sym) }
  case {users: users}
  in {users: [{name:}, *]} then name
  else nil
  end
end
