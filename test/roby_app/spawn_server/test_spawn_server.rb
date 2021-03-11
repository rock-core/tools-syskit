# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::LogTransferServer::SpawnServer do
    class TestServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        attr_accessor :user, :password, :certfile_path

        def initialize(target_dir, user, password)
            @certfile_path = File.join(__dir__, "..", "remote_processes", "cert.pem")
            super(target_dir, user, password, @certfile_path)
            @user = user
            @password = password
        end
    end

    ### AUXILIARY FUNCTIONS ###
    def spawn_server
        @temp_dir = Ftpd::TempDir.make
        @user = "test.user"
        @password = "test.password"
        @server = TestServer.new(@temp_dir, @user, @password)
    end

    def upload_log(host, port, certificate, user, password, localfile) # rubocop:disable Metrics/ParameterLists
        Net::FTP.open(host, port: port, verify_mode: OpenSSL::SSL::VERIFY_PEER,
                            ca_file: certificate) do |ftp|
            ftp.login(user, password)
            File.open(localfile) do |lf|
                ftp.storbinary("STOR #{File.basename(localfile)}",
                               lf, Net::FTP::DEFAULT_BLOCKSIZE)
            end
        end
    end

    def upload_testfile
        File.open("testfile", "w+") do |tf|
            upload_log("127.0.0.1", @server.port, @server.certfile_path,
                       @server.user, @server.password, tf)
        end
    end

    def delete_testfile
        File.delete(Dir.pwd + "/testfile")
    end

    ### TESTS ###
    describe "#LogTransferServerTests" do
        before do
            spawn_server
        end

        it "tests connection to server" do
            Net::FTP.open(
                "127.0.0.1",
                port: @server.port,
                verify_mode: OpenSSL::SSL::VERIFY_PEER,
                ca_file: @server.certfile_path
            ) do |ftp|
                assert ftp.login(@server.user, @server.password),
                       "FTP server doesn't connect."
            end
        end

        it "incorrect user tests connection to server" do
            Net::FTP.open(
                "127.0.0.1",
                port: @server.port,
                verify_mode: OpenSSL::SSL::VERIFY_PEER,
                ca_file: @server.certfile_path
            ) do |ftp|
                assert_raises(Net::FTPPermError) { ftp.login("user", @server.password) }
            end
        end

        it "incorrect password tests connection to server" do
            Net::FTP.open(
                "127.0.0.1",
                port: @server.port,
                verify_mode: OpenSSL::SSL::VERIFY_PEER,
                ca_file: @server.certfile_path
            ) do |ftp|
                assert_raises(Net::FTPPermError) { ftp.login(@server.user, "password") }
            end
        end

        it "tests file uploads to server" do
            upload_testfile
            assert File.exist?("#{@temp_dir}/testfile"), "Uploaded file doesn't exist."
            delete_testfile
        end

        it "tests upload of file that already exists" do
            upload_testfile
            assert_raises(Net::FTPPermError) { upload_testfile }
            delete_testfile
        end

        it "tests read function blocking of remote repository" do
            upload_testfile
            Net::FTP.open(
                "127.0.0.1",
                port: @server.port,
                verify_mode: OpenSSL::SSL::VERIFY_PEER,
                ca_file: @server.certfile_path
            ) do |ftp|
                ftp.login(@server.user, @server.password)
                assert_raises(Net::FTPPermError) { ftp.get("#{@temp_dir}/testfile") }
            end
            delete_testfile
        end
    end
end
