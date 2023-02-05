# frozen_string_literal: true

module Syskit
    module RobyApp
        # High-level interface to log transfer for the benefit of {Plugin}
        class LogTransferManager
            # @param [Roby::Application] app
            # @param [Configuration] conf
            def initialize(conf = Syskit.conf.log_transfer)
                @conf = conf

                unless @conf.ip
                    raise ArgumentError, "log transfer is enabled, but the ip is not set"
                end

                unless @conf.target_dir
                    raise ArgumentError, "log transfer is enabled, but target_dir not set"
                end

                server_start if @conf.self_spawned?
            end

            # Stop log transfer
            def dispose(process_servers, flush: true)
                return unless server_started?

                self.flush(process_servers) if flush
                server_stop
            end

            # Start an in-process server suitable to receive remote process files
            #
            # It auto-generates the password and certificates, and updates the
            # configuration accordingly
            def server_start
                raise ArgumentError, "log transfer server already running" if @server

                server_update_self_spawned_conf
                @server = LogTransferServer::SpawnServer.new(
                    @conf.target_dir, @conf.user, @conf.password,
                    @self_signed_ca.private_certificate_path,
                    interface: @conf.ip,
                    implicit_ftps: @conf.implicit_ftps?
                )
                @conf.port = @server.port
            end

            def server_update_self_spawned_conf
                @self_signed_ca = TmpRootCA.new(@conf.ip)
                @conf.user ||= "Syskit"
                @conf.password ||= SecureRandom.base64(32)
                @conf.certificate = @self_signed_ca.certificate
            end

            # Whether files from the given directory should be transferred
            def transfer_local_files_from?(dir)
                @conf.target_dir != dir
            end

            # Transfer the given files to the FTP server configured in
            # {Configuration#log_transfer}
            #
            # @param [Array<(String, RemoteProcesses::Client, Array<String>)>] logs
            #   list of logs to transfer, per remote server
            def transfer(logs)
                logs.each do |process_server, paths|
                    transfer_one_process_server_logs(process_server, paths)
                end
            end

            # @api private
            #
            # Transfer log files of a single process server
            #
            # @param [RemoteProcesses::Client] process_server
            # @param [Array<String>] logfiles
            def transfer_one_process_server_logs(process_server, paths)
                upload_rate = @conf.max_upload_rate_for(process_server.name)
                paths.each do |path|
                    process_server.client.log_upload_file(
                        @conf.ip, @conf.port, @conf.certificate,
                        @conf.user, @conf.password, Pathname(path),
                        max_upload_rate: upload_rate,
                        implicit_ftps: @conf.implicit_ftps?
                    )
                end
            end

            # Whether the in-process transfer server has been started
            def server_started?
                @server
            end

            # Wait for all pending transfers to finish
            #
            # @return [{RemoteProcesses::Client=>Array<LogUploadState::Result>}]
            def flush(process_servers, poll_period: 0.5, timeout: 600)
                results = {}
                deadline = Time.now + timeout
                process_servers.each { |c| results[c] = [] }
                loop do
                    process_servers = flush_poll_servers(process_servers, results)
                    break if process_servers.empty?

                    if Time.now > deadline
                        raise Timeout::Error,
                              "failed to flush all pending file transfers "\
                              "within #{timeout} seconds"
                    end

                    sleep(poll_period)
                end

                results
            end

            # @api private
            #
            # Do a single pass to flush clients
            #
            # @return the set of clients that are not finished with transfers
            def flush_poll_servers(process_servers, results)
                process_servers.find_all do |config|
                    c = config.client
                    state = c.log_upload_state
                    results[config].concat(state.each_result.to_a)
                    next(false) if state.pending_count == 0

                    ::Robot.info "Waiting for process server at #{c.host} "\
                                 "to finish uploading"
                    true
                end
            end

            def server_stop
                @server.stop
                @server.join
                @self_signed_ca.dispose
                @server = nil
                @self_signed_ca = nil
            end

            Configuration = Struct.new(
                :enabled, :ip, :port, :user, :password, :certificate,
                :self_spawned, :target_dir, :default_max_upload_rate,
                :max_upload_rates, :implicit_ftps,
                keyword_init: true
            ) do
                def enabled?
                    enabled
                end

                def self_spawned?
                    self_spawned
                end

                def implicit_ftps?
                    implicit_ftps
                end

                # Return the upload rate limit for a given process server
                #
                # If {#max_upload_rate} contains an entry for this process server
                # (keyed by name), it returns it. Otherwise, returns
                # {#default_max_upload_rate}
                #
                # @param [ProcessServerConfig,String] process_server the process server
                #   object or its name
                def max_upload_rate_for(process_server, default: default_max_upload_rate)
                    name =
                        if process_server.respond_to?(:name)
                            process_server.name
                        else
                            process_server.to_str
                        end

                    max_upload_rates[name] || default
                end
            end
        end
    end
end
