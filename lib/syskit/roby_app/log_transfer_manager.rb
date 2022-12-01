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

            def dispose(clients, flush: true)
                return unless server_started?

                self.flush(clients) if flush
                server_stop
            end

            # Start an in-process server suitable to receive remote process files
            #
            # It auto-generates the password and certificates, and updates the
            # configuration accordingly
            def server_start
                raise ArgumentError, "log transfer server already running" if @server

                @self_signed_ca = TmpRootCA.new(@conf.ip)
                @conf.user ||= "Syskit"
                @conf.password ||= SecureRandom.base64(32)
                @conf.certificate = @self_signed_ca.certificate

                @server = LogTransferServer::SpawnServer.new(
                    @conf.target_dir, @conf.user, @conf.password,
                    @self_signed_ca.private_certificate_path
                )
                @conf.port = @server.port
            end

            # Whether files from the given directory should be transferred
            def transfer_local_files_from?(dir)
                conf.target_dir != dir
            end

            # Transfer the given files to the FTP server configured in
            # {Configuration#log_transfer}
            #
            # @param [Array<(String, RemoteProcesses::Client, Array<String>)>] logs
            #   list of logs to transfer, per remote server
            def transfer(logs)
                logs.each do |name, client, paths|
                    transfer_one_process_server_logs(name, client, paths)
                end
            end

            # @api private
            #
            # Transfer log files of a single process server
            #
            # @param [RemoteProcesses::Client] process_server
            # @param [Array<String>] logfiles
            def transfer_one_process_server_logs(name, client, paths)
                paths.each do |path|
                    client.log_upload_file(
                        @conf.ip, @conf.port, @conf.certificate,
                        @conf.user, @conf.password, Pathname(path),
                        max_upload_rate: @conf.max_upload_rate_for(name)
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
            def flush(clients, poll_period: 0.5, timeout: 600)
                results = {}
                deadline = Time.now + timeout
                clients.each { |c| results[c] = [] }
                loop do
                    clients = flush_poll_clients(clients, results)
                    break if clients.empty?

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
            def flush_poll_clients(clients, results)
                clients.find_all do |c|
                    state = c.log_upload_state
                    results[c].concat(state.each_result.to_a)
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
                :max_upload_rates,
                keyword_init: true
            ) do
                def enabled?
                    enabled
                end

                def self_spawned?
                    self_spawned
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
