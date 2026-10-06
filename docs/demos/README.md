# Terminal demos

Two short [VHS](https://github.com/charmbracelet/vhs) recordings use the README's
access check and live Branchproof output:

- [MC/DC](mcdc.gif): passing tests and complete decision coverage, an unproven
  suspension condition, then the additional test and passing MC/DC gate.
- [Decision table](decision-table.gif): the missing `TT` rule, then all three
  short-circuit rules covered.

`suspension_test.rb` loads the original two tests and adds a third. No output is
mocked or rewritten. The tapes clear the screen between scenes; longer reports
scroll naturally. The README provides a static, accessible explanation too.

## Record again

Install VHS, ffmpeg, and ttyd, and select CRuby 4.0 or newer. From the repository
root, with the development bundle installed:

```sh
bundle install
ruby docs/demos/record.rb
```

The Ruby helper copies the three example files into ignored `tmp/demos/`, sets
`BUNDLE_GEMFILE` to this checkout, and runs both tapes. It overwrites only those
sample files, the two GIFs, and review screenshots under `tmp/demos/`. Existing
application files are never used. Select your Ruby before recording; the tapes
contain no machine-specific Ruby paths.

To change the demo, edit the sample Ruby files or tapes, rerun the command, and
review the screenshots and GIFs. Verify that the initial MC/DC gate fails with
passing tests, the final gate passes, and the table changes from 2/3 to 3/3.
The GIFs are documentation assets and are not included in the gem package.
