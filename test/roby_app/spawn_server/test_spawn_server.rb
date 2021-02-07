# frozen_string_literal: true

require "minitest/autorun"
require "minitest/spec"

require "ftpd"
require "net/ftp"

require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::LogTransferServer::SpawnServer do

    class TestServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        include Ftpd::InsecureCertificate

        attr_accessor :user, :password, :certfile_path

        def initialize(
            tgt_dir, 
            user = "test.user", 
            password = "test.password", 
            certfile_path = insecure_certfile_path)
            super
        end
    end

    ### AUXILIARY FUNCTIONS ###
    def spawn_server
        @temp_dir = Ftpd::TempDir.make
        @server = TestServer.new(@temp_dir)
    end

    def upload_log(host, port, certificate, user, password, localfile)
        Net::FTP.open(host, port: port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: certificate) do |ftp|
            ftp.login(user, password)
            lf = File.open(localfile)
            ftp.storbinary("STOR #{File.basename(localfile)}", lf, Net::FTP::DEFAULT_BLOCKSIZE)
        end
    end

    def upload_testfile
        File.new("testfile", "w+")
        upload_log(@server.interface, @server.port, @server.certfile_path, @server.user, @server.password, "testfile")
        File.delete("testfile")
    end

    ### TESTS ###
    describe "#LogTransferServerTests" do

        before do
            spawn_server
        end
        
        it "tests connection to server" do
            Net::FTP.open(
                @server.interface, 
                port: @server.port, 
                verify_mode: OpenSSL::SSL::VERIFY_PEER, 
                ca_file: @server.certfile_path) do |ftp|
                
                assert ftp.login(@server.user, @server.password), "FTP server doesn't connect."
            end
        end

        it "tests file uploads to server" do
            upload_testfile
            assert File.exist?("#{@temp_dir}/testfile"), "Uploaded file doesn't exist."
        end

        it "tests upload of file that already exists" do
            upload_testfile
            assert_raises(Net::FTPPermError) {upload_testfile}
        end

        it "tests read function blocking of remote repository" do
            upload_testfile
            Net::FTP.open(
                @server.interface, 
                port: @server.port, 
                verify_mode: OpenSSL::SSL::VERIFY_PEER, 
                ca_file: @server.certfile_path) do |ftp|
                
                ftp.login(@server.user, @server.password)
                assert_raises(Net::FTPPermError) { ftp.get("#{@temp_dir}/testfile") }
            end
        end

    end
end

