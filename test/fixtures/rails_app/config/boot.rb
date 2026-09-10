# frozen_string_literal: true

require "fileutils"

require "bootsnap/setup"
FileUtils.mkdir_p(File.expand_path("../tmp", __dir__))
File.write(File.expand_path("../tmp/bootsnap_loaded", __dir__), "1")
