# frozen_string_literal: true

# NOTE: this is NOT integrated in the Thor-based CLI to make it more independent
# (i.e. not depending on actually having Syskit installed)

require "pathname"
require "thor"
require "syskit/cli/log_runtime_archive"
require "syskit/cli/log_runtime_archive_main"

Syskit::CLI::LogRuntimeArchiveMain.start(ARGV)
