# frozen_string_literal: true

require "pathname"
require "syskit/cli/log_runtime_archive"

unless ARGV.size == 2
    STDERR.puts "usage: log_runtime_archive ROOT_DIR TARGET_DIR"
    exit 1
end

root_dir = Pathname.new(ARGV[0])
target_dir = Pathname.new(ARGV[1])

if !root_dir.directory?
    warn "#{root_dir} is not a directory"
    exit 1
elsif !target_dir.directory?
    warn "#{target_dir} is not a directory"
    exit 1
end

POLLING_PERIOD = 600

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

loop do
    Syskit::CLI::LogRuntimeArchive.process_root_folder(
        root_dir, target_dir, logger: logger
    )

    puts "Archived pending logs, sleeping #{POLLING_PERIOD}s"
    sleep POLLING_PERIOD
end
