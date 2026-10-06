Output docs/demos/decision-table.gif
Source docs/demos/setup.tape

Type "# Which input combinations have our tests exercised?"
Enter
Type "cat access.rb access_test.rb"
Enter
Wait+Line /\$$/
Sleep 7s

Ctrl+L
Type "bundle exec branchproof analyze access.rb --test access_test.rb --view decision-tables --level 1"
Enter
Wait+Line /\$$/
Sleep 10s
Screenshot tmp/demos/table-missing.png
Sleep 500ms

Ctrl+L
Type "# Cover the missing TT rule: paid=true, suspended=true."
Enter
Type "cat suspension_test.rb"
Enter
Wait+Line /\$$/
Sleep 5s

Ctrl+L
Type "bundle exec branchproof analyze access.rb --test suspension_test.rb --view decision-tables --level 1"
Enter
Wait+Line /\$$/
Sleep 10s
Screenshot tmp/demos/table-covered.png
Sleep 500ms
