# frozen_string_literal: true

# NOTE: this is NOT integrated in the Thor-based CLI to make it more independent
# (i.e. not depending on actually having Syskit installed)

require "pathname"
require "thor"
require "syskit/cli/log_runtime_archive"
require "syskit/runtime/server/spawn_server"

module Syskit
    module CLI
        # Command-line definition for the cli-archive-main syskit subcommand
        class LogRuntimeArchiveMain < Thor
            def self.exit_on_failure?
                true
            end

            desc "watch ROOT_DIR TARGET_DIR",
                 "watch a dataset root folder and call archiver"
            option :period,
                   type: :numeric, default: 600, desc: "polling period in seconds"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            default_task def watch(root_dir, target_dir)
                logger = create_logger
                loop do
                    begin
                        archive(root_dir, target_dir)
                    rescue Errno::ENOSPC
                        next
                    end

                    logger.info("Archived pending logs, sleeping #{options[:period]}s")
                    sleep options[:period]
                end
            end

            desc "archive ROOT_DIR TARGET_DIR",
                 "archive the datasets and manages disk space"
            option :max_size,
                   type: :numeric, default: 10_000, desc: "max log size in MB"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            def archive(root_dir, target_dir)
                root_dir = validate_directory_exists(root_dir)
                target_dir = validate_directory_exists(target_dir)
                archiver = make_archiver(root_dir, target_dir: target_dir)

                archiver.ensure_free_space(
                    options[:free_space_low_limit] * 1_000_000,
                    options[:free_space_freed_limit] * 1_000_000
                )
                archiver.process_root_folder(
                    max_archive_size: options[:max_size] * (1024**2)
                )
            end

            desc "watch_transfer SOURCE_DIR HOST PORT CERTIFICATE_PATH USER PASSWORD",
                 "watches a dataset root folder and periodically performs transfer"
            option :period,
                   type: :numeric, default: 600, desc: "polling period in seconds"
            option :max_upload_rate_mbps,
                   type: :numeric, default: 1_000, desc: "max upload rate in Mbps"
            option :implicit_ftps,
                   type: :boolean, default: false,
                   desc: "use implicit connection method for ftps " \
                         "(disable for 2.5 clients on 2.7 servers)"
            option :min_required_space,
                   type: :numeric, default: 10_000,
                   desc: "min space in source_dir, in MB, required to perform transfer"
            def watch_transfer( # rubocop:disable Metrics/ParameterLists
                source_dir, host, port, certificate_path, user, password
            )
                logger = create_logger
                loop do
                    begin
                        transfer(source_dir, host, port, certificate_path, user, password)
                    rescue Errno::ENOSPC
                        next
                    end

                    logger.info("Transferred pending logs, sleeping #{options[:period]}s")
                    sleep options[:period]
                end
            end

            desc "transfer SOURCE_DIR HOST PORT CERTIFICATE_PATH USER PASSWORD",
                 "transfers the datasets"
            option :max_upload_rate_mbps,
                   type: :numeric, default: 1_000, desc: "max upload rate in Mbps"
            option :implicit_ftps,
                   type: :boolean, default: false,
                   desc: "use implicit connection method for ftps " \
                         "(disable for 2.5 clients on 2.7 servers)"
            option :min_required_space,
                   type: :numeric,
                   default: 10_000,
                   desc: "min space in source_dir, in MB, required to perform transfer"
            def transfer( # rubocop:disable Metrics/ParameterLists
                source_dir, host, port, certificate_path, user, password
            )
                source_dir = validate_directory_exists(source_dir)
                archiver = make_archiver(source_dir)

                server_params = LogRuntimeArchive::FTPParameters.new(
                    host: host, port: port, certificate: File.read(certificate_path),
                    user: user, password: password,
                    implicit_ftps: options[:implicit_ftps],
                    max_upload_rate: rate_mbps_to_bps(options[:max_upload_rate_mbps])
                )
                archiver.process_root_folder_transfer(server_params,
                                                      options[:min_required_space])
            end

            desc "transfer_server TARGET_DIR HOST PORT CERTFILE_PATH USER PASSWORD",
                 "creates the log transfer FTP server that runs on the main computer"
            option :implicit_ftps,
                   type: :boolean, default: false,
                   desc: "use implicit connection method for ftps " \
                         "(disable for 2.5 clients on 2.7 servers)"
            def transfer_server( # rubocop:disable Metrics/ParameterLists
                target_dir, host, port, certfile_path, user, password
            )
                server = create_server(target_dir, host, port, certfile_path, user,
                                       password, options[:implicit_ftps])
                server.run
            end

            desc "watch_ensure_free_space SOURCE_DIR",
                 "watches the ensure free space process"
            option :period,
                   type: :numeric, default: 10, desc: "polling period in seconds"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            def watch_ensure_free_space(source_dir)
                logger = create_logger
                loop do
                    ensure_free_space(source_dir)

                    logger.info(
                        "Ensured free space in #{source_dir}, sleeping " \
                        "#{options[:period]}s"
                    )
                    sleep options[:period]
                end
            end

            desc "ensure_free_space SOURCE_DIR",
                 "ensures there is free space, if not, start deleting files"
            option :free_space_low_limit,
                   type: :numeric, default: 5_000, desc: "start deleting files if \
                    available space is below this threshold (threshold in MB)"
            option :free_space_freed_limit,
                   type: :numeric, default: 25_000, desc: "stop deleting files if \
                    available space is above this threshold (threshold in MB)"
            def ensure_free_space(source_dir)
                source_dir = validate_directory_exists(source_dir)

                archiver = make_archiver(source_dir)

                source_dir.children.select(&:directory?).sort_by(&:mtime).each do |child|
                    break if archiver.ensure_free_space(
                        options[:free_space_low_limit] * 1_000_000,
                        options[:free_space_freed_limit] * 1_000_000,
                        directory: (source_dir / child)
                    )
                end
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                # Converts rate in Mbps to bps
                def rate_mbps_to_bps(rate_mbps)
                    rate_mbps * (10**6)
                end

                def validate_directory_exists(dir)
                    dir = Pathname.new(dir)
                    unless dir.directory?
                        raise ArgumentError, "#{dir} does not exist, or is not a " \
                                             "directory"
                    end

                    dir
                end

                def make_archiver(root_dir, target_dir: nil)
                    logger = Logger.new($stdout)

                    Syskit::CLI::LogRuntimeArchive.new(
                        root_dir,
                        target_dir: target_dir, logger: logger
                    )
                end

                def create_server( # rubocop:disable Metrics/ParameterLists
                    target_dir, host, port, certificate, user, password, implicit_ftps
                )
                    Runtime::Server::SpawnServer.new(
                        target_dir, user, password,
                        certificate,
                        interface: host,
                        port: port,
                        implicit_ftps: implicit_ftps
                    )
                end

                def create_logger
                    $stdout.sync = true
                    Logger.new($stdout)
                end
            end
        end
    end
end
