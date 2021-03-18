# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::LogTransferServer::SpawnServer do
    class TestServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        attr_accessor :user, :password, :certfile_path

        def initialize(target_dir, user, password)
            @certfile_path = File.join(__dir__, "..", "remote_processes", "cert.crt")
            private_key_path = File.join(
                __dir__, "..", "remote_processes", "cert-private.crt"
            )
            super(target_dir, user, password, private_key_path)
            @user = user
            @password = password
        end
    end

    ### AUXILIARY FUNCTIONS ###
    def spawn_server
        @temp_serverdir = make_tmpdir
        @user = "test.user"
        @password = "test.password"
        @server = TestServer.new(@temp_serverdir, @user, @password)
    end

    def ftp_open(certfile_path: @server.certfile_path, &block)
        Net::FTP.open(
            "localhost",
            port: @server.port,
            ssl: { verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: false,
                   ca_file: certfile_path },
            &block
        )
    end

    def upload_log(user, password, localfile, certfile_path: @server.certfile_path)
        ftp_open(certfile_path: certfile_path) do |ftp|
            ftp.login(user, password)
            File.open(localfile) do |lf|
                ftp.storbinary("STOR #{File.basename(localfile)}",
                               lf, Net::FTP::DEFAULT_BLOCKSIZE)
            end
        end
    end

    def upload_testfile
        File.open(File.join(@temp_srcdir, "testfile"), "w+") do |tf|
            upload_log(@server.user, @server.password, tf)
        end
    end

    ### TESTS ###
    describe "#LogTransferServerTests" do
        before do
            spawn_server
            @temp_srcdir = make_tmpdir
        end

        it "logs in successfully with the correct user and password" do
            ftp_open do |ftp|
                # Raises on error
                ftp.login(@server.user, @server.password)
            end
        end

        it "rejects an invalid user" do
            ftp_open do |ftp|
                assert_raises(Net::FTPPermError) { ftp.login("user", @server.password) }
            end
        end

        it "rejects an invalid password" do
            ftp_open do |ftp|
                assert_raises(Net::FTPPermError) { ftp.login(@server.user, "password") }
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
            assert File.exist?("#{@temp_serverdir}/testfile"),
                   "cannot find the expected upload"
        end

        it "refuses to upload a file that already exists" do
            upload_testfile
            assert_raises(Net::FTPPermError) { upload_testfile }
        end

        it "refuses to GET a file" do
            upload_testfile
            ftp_open do |ftp|
                ftp.login(@server.user, @server.password)
                assert_raises(Net::FTPPermError) do
                    ftp.get("#{@temp_serverdir}/testfile")
                end
            end
        end
    end
end
