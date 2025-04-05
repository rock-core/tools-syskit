# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/log_transfer_server"
require "net/ftp"

module Syskit
    module Runtime
        module Server
            describe SpawnServer do
                ### TESTS ###
                before do
                    @source_dir = make_tmppath
                    @target_dir = make_tmppath
                    spawn_server
                end

                after do
                    @cert_io&.close
                    @server.stop
                    @server.join
                end

                it "logs in successfully with the correct user and password" do
                    ftp_open do |ftp|
                        # Raises on error
                        ftp.login("user", "password")
                    end
                end

                it "rejects an invalid user" do
                    ftp_open do |ftp|
                        assert_raises(Net::FTPPermError) do
                            ftp.login("invalid", "password")
                        end
                    end
                end

                it "rejects an invalid password" do
                    ftp_open do |ftp|
                        assert_raises(Net::FTPPermError) do
                            ftp.login("user", "invalid")
                        end
                    end
                end

                it "refuses to connect if the server's certificate is unexpected" do
                    invalid_certfile_path = File.join(
                        __dir__, "..", "remote_processes", "invalid-cert.crt"
                    )

                    e = assert_raises(OpenSSL::SSL::SSLError) do
                        ftp_open(certfile_path: invalid_certfile_path)
                    end
                    assert_match(/certificate verify failed/, e.message)
                end

                it "uploads a file to the server's directory" do
                    upload_testfile
                    assert File.exist?("#{@target_dir}/testfile")
                end

                it "refuses to upload a file that already exists" do
                    (@target_dir / "testfile").write("")
                    e = assert_raises(Net::FTPPermError) { upload_testfile }
                    assert_match(/Already exist/, e.message)
                end

                it "assumes a transfer did not finish if the partial file is present, " \
                   "and allows overwriting" do
                    (@target_dir / "testfile.partial").write("")
                    upload_testfile
                end

                it "refuses to upload a file if the disk space is below threshold " \
                   "at the beginning" do
                    # The default threshold is zero ... let's invent negative disk space
                    flexmock(Sys::Filesystem)
                        .should_receive(:stat)
                        .with(@target_dir.to_s)
                        .and_return(flexmock(bytes_available: -1))
                    e = assert_raises(Net::FTPPermError) { upload_testfile }
                    assert_match(/less than 0 bytes available/, e.message)
                end

                it "validates the disk space after each chunk" do
                    flexmock(Sys::Filesystem)
                        .should_receive(:stat)
                        .with(@target_dir.to_s)
                        .and_return(flexmock(bytes_available: -1))
                    e = assert_raises(Net::FTPPermError) { upload_testfile }
                    assert_match(/less than 0 bytes available/, e.message)
                end

                it "refuses to GET a file" do
                    upload_testfile
                    ftp_open do |ftp|
                        ftp.login("user", "password")
                        assert_raises(Net::FTPPermError) do
                            ftp.get("#{@target_dir}/testfile")
                        end
                    end
                end

                def spawn_server
                    @ca = RobyApp::TmpRootCA.new("127.0.0.1")

                    @implicit_ftps = Server.use_implicit_ftps?
                    @server = SpawnServer.new(
                        @target_dir, "user", "password", @ca.private_certificate_path,
                        interface: "127.0.0.1", implicit_ftps: @implicit_ftps
                    )
                    @certfile_io = Tempfile.open
                    @certfile_io.write @ca.certificate
                    @certfile_io.flush
                    @certfile_path = @certfile_io.path
                end

                def ftp_open(certfile_path: @certfile_path, &block)
                    Net::FTP.open(
                        "127.0.0.1",
                        private_data_connection: false,
                        port: @server.port, implicit_ftps: @implicit_ftps,
                        ssl: { verify_mode: OpenSSL::SSL::VERIFY_PEER,
                               ca_file: certfile_path },
                        &block
                    )
                end

                def upload_log(path, certfile_path: @certfile_path)
                    ftp_open(certfile_path: certfile_path) do |ftp|
                        ftp.login("user", "password")
                        File.open(path) do |io|
                            ftp.storbinary(
                                "STOR #{File.basename(path)}",
                                io, Net::FTP::DEFAULT_BLOCKSIZE
                            )
                        end
                    end
                end

                def upload_testfile(size: 1024)
                    testfile_path = File.join(@source_dir, "testfile")
                    make_random_file(testfile_path, size: size)
                    upload_log(testfile_path)
                end

                def make_random_file(path, size: 1024)
                    content = Base64.encode64(Random.bytes(size))
                    File.write(path, content)
                    content
                end
            end
        end
    end
end
