# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive"
require "syskit/runtime/server/spawn_server"

module Syskit
    module RobyApp
        module LogTransferServer
            describe FTPUpload do
                before do
                    @ca = RobyApp::TmpRootCA.new("127.0.0.1")

                    @source_dir = make_tmppath
                    @target_dir = make_tmppath
                    @server = create_server
                    @port = @server.port
                end

                after do
                    @server.stop
                    @server.join
                    @ca.dispose
                end

                it "reports an error" do
                    ftp = create_ftp_upload(@source_dir / "file")
                    result = ftp.open_and_transfer
                    refute result.success?
                    assert_match(/No such file or directory/, result.message)

                    refute (@target_dir / "file.partial").exist?
                    refute (@target_dir / "file").exist?
                end

                def create_ftp_upload(file)
                    FTPUpload.new(
                        "127.0.0.1", @server.port, @ca.certificate,
                        "user", "password", file,
                        implicit_ftps: Runtime::Server.use_implicit_ftps?
                    )
                end

                def create_server
                    Runtime::Server::SpawnServer.new(
                        @target_dir, "user", "password",
                        @ca.private_certificate_path,
                        interface: "127.0.0.1",
                        implicit_ftps: Runtime::Server.use_implicit_ftps?
                    )
                end
            end
        end
    end
end
