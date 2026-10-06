Output docs/demos/mcdc.gif
Source docs/demos/setup.tape

Type "# Both branches run. Does suspension actually block access?"
Enter
Type "cat access.rb access_test.rb"
Enter
Wait+Line /\$$/
Sleep 7s
Screenshot tmp/demos/mcdc-code.png
Sleep 500ms

Ctrl+L
Type "bundle exec branchproof analyze access.rb --test access_test.rb --view summary --level 1 --minimum mcdc=100"
Enter
Wait+Line /\$$/
Sleep 6s
Screenshot tmp/demos/mcdc-gap.png
Sleep 500ms

Ctrl+L
Type "bundle exec branchproof analyze access.rb --test access_test.rb --view conditions --missing-only"
Enter
Wait+Line /\$$/
Sleep 10s
Screenshot tmp/demos/mcdc-evidence.png
Sleep 500ms

Ctrl+L
Type "# Add the missing case: paid AND suspended must be denied."
Enter
Type "cat suspension_test.rb"
Enter
Wait+Line /\$$/
Sleep 5s
Type "bundle exec branchproof analyze access.rb --test suspension_test.rb --view summary --level 1 --minimum mcdc=100"
Enter
Wait+Line /\$$/
Sleep 7s
Screenshot tmp/demos/mcdc-passed.png
Sleep 500ms
