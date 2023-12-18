# frozen_string_literal: true

# NOTE: this is NOT integrated in the Thor-based CLI to make it more independent
# (i.e. not depending on actually having Syskit installed)

require "pathname"
require "thor"
require "syskit/cli/log_runtime_archive"

# Command-line definition for the log-runtime-archive syskit subcommand
class CLI < Thor
    def self.exit_on_failure?
        true
    end

    desc "watch", "watch a dataset root folder and archive the datasets"
    option :period,
           type: :numeric, default: 600, desc: "polling period in seconds"
    option :max_size,
           type: :numeric, default: 10_000, desc: "max log size in MB"
    option :free_space_low_limit,
            type: :numeric, default: 1_000, desc: "start deleting files if free space is \
            below this threshold"
    option :free_space_delete_until,
            type: :numeric, default: 10_000, desc: "stop deleting files if free space is \
            above this threshold"
    default_task def watch(root_dir, target_dir)
        root_dir = validate_directory_exists(root_dir)
        target_dir = validate_directory_exists(target_dir)
        archiver = make_archiver(root_dir, target_dir)
        loop do
            archiver.process_root_folder
            archiver.ensure_free_space(
                options[:free_space_low_limit], options[:free_space_delete_until]
            )

            puts "Archived pending logs, sleeping #{options[:period]}s"
            sleep options[:period]
        end
    end

    no_commands do
        def validate_directory_exists(dir)
            dir = Pathname.new(dir)
            unless dir.directory?
                raise ArgumentError, "#{dir} does not exist, or is not a directory"
            end

            dir
        end

        def make_archiver(root_dir, target_dir)
            logger = Logger.new(STDOUT)

            Syskit::CLI::LogRuntimeArchive.new(
                root_dir, target_dir,
                logger: logger, max_archive_size: options[:max_size] * 1024**2
            )
        end
    end
end

CLI.start(ARGV)
