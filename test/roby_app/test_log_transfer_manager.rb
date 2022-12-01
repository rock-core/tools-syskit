# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test/roby_app_helpers"
require "syskit/roby_app/remote_processes"

module Syskit
    module RobyApp
        describe LogTransferManager do
            before do
                @server_threads = []
                @clients = []
                @client, @remote_dir_path = create_process_server

                @conf = LogTransferManager::Configuration.new(
                    ip: "127.0.0.1",
                    self_spawned: true,
                    max_upload_rates: {}
                )
                @conf.target_dir = make_tmpdir
                @manager = nil
            end

            after do
                @manager&.dispose(@clients)
                close_process_servers
            end

            it "sets an in-process server and allows file transfers" do
                @conf.ip = "127.0.0.1"
                file_path = create_test_file(@remote_dir_path)
                @manager = LogTransferManager.new(@conf)
                assert @manager.server_started?
                @manager.transfer([["test", @client, [file_path.basename]]])
                assert_upload_succeeds(file_path, @client)
            end

            it "stops the in-process server on dispose" do
                @conf.ip = "127.0.0.1"
                @manager = LogTransferManager.new(@conf)
                # Check that the server is reachable
                TCPSocket.new(@conf.ip, @conf.port).close
                @manager.dispose([@client])
                assert_raises(Errno::ECONNREFUSED) do
                    TCPSocket.new(@conf.ip, @conf.port)
                end
            end

            it "refuses to upload a file that is outside the log dir" do
                @conf.ip = "127.0.0.1"
                @manager = LogTransferManager.new(@conf)
                other_path = make_tmppath
                passwd_abs = other_path / "passwd"
                passwd_rel = passwd_abs.relative_path_from(@remote_dir_path).to_s
                passwd_abs.write("test")
                @manager.transfer([["test", @client, [passwd_rel]]])
                assert_upload_fails(
                    @client, /cannot upload files not within the app's log directory/
                )
                @manager.transfer([["test", @client, [passwd_abs]]])
                assert_upload_fails(
                    @client, /cannot upload files not within the app's log directory/
                )
            end

            it "handles an externally started server" do
                @conf.ip = "127.0.0.1"
                @conf.self_spawned = false
                @conf.user = "user"
                @conf.password = "password"
                target_path = make_tmppath
                @conf.target_dir = target_path.to_s
                ca = TmpRootCA.new("127.0.0.1")
                @conf.certificate = ca.certificate
                server = LogTransferServer::SpawnServer.new(
                    target_path.to_s, "user", "password",
                    ca.private_certificate_path
                )
                @conf.port = server.port

                file_path = create_test_file(@remote_dir_path)
                @manager = LogTransferManager.new(@conf)
                @manager.transfer([["test", @client, [file_path.basename]]])
                assert_upload_succeeds(file_path, @client)
                @manager.dispose([@client])
            ensure
                server&.dispose
            end

            # Spawn a process server
            #
            # @return [(RemoteProcesses::Client,Pathname)]
            def create_process_server
                server = RemoteProcesses::Server.new(app, port: 0)
                server.open
                thread = Thread.new { server.listen }

                client = RemoteProcesses::Client.new("localhost", server.port)
                @server_threads << thread
                @clients << client
                log_dir = config_log_dir(client)
                [client, log_dir]
            rescue StandardError
                server.quit_and_join
                raise
            end

            def config_log_dir(client)
                dir = make_tmppath
                client.create_log_dir(
                    dir.to_s, Roby.app.time_tag,
                    { "parent" => Roby.app.app_metadata }
                )
                dir.each_child.first
            end

            def close_process_servers
                @clients.each do |client|
                    client.quit_server
                    client.close
                end

                @server_threads.each(&:join)
            end

            def create_test_file(dir_path)
                file_path = dir_path / "testfile.log"
                file_path.write(SecureRandom.random_bytes(547))
                file_path
            end

            def assert_upload_fails(client, match)
                result = assert_upload_with_single_result(@manager, client)

                refute result.success?
                assert_match(match, result.message)
            end

            def assert_upload_succeeds(test_file_path, client)
                result = assert_upload_with_single_result(@manager, client)

                assert result.success?, "transfer failed, message: #{result.message}"
                assert_equal test_file_path.basename.to_s, result.file
                actual_content = File.read(
                    File.join(@conf.target_dir, result.file)
                )
                assert_equal test_file_path.read, actual_content
            end

            def assert_upload_with_single_result(manager, client)
                transfers = manager.flush([client], timeout: 1)
                assert_equal [client], transfers.keys
                assert_equal 1, transfers[client].size
                transfers[client].first
            end
        end
    end
end
