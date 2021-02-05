# frozen_string_literal: true

require "minitest/autorun"
require "minitest/spec"

require "ftpd"
require "net/ftp"

require "lib/syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::LogTransferServer::SpawnServer do

    class TestServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        include Ftpd::InsecureCertificate

        attr_accessor :certfile_path

        def initialize(tgt_dir, user: "test.user", password: "test.password")
            super
            @user = user
            @password = password
            @certfile_path = insecure_certfile_path
        end
    end 
    
    ### AUXILIARY FUNCTIONS ###
    def spawn_server
        @temp_dir = Ftpd::TempDir.make
        @server = TestServer.new(@temp_dir, user: "test.user", password: "test.password")
    end

    def upload_testfile
        File.new("testfile", "w+")
        upload_log("127.0.0.1", @server.port, @certificate, "test.user", "", "testfile")
        File.delete("testfile")
    end

    def spawn_and_upload_testfile
        spawn_server
        upload_testfile
    end

    def upload_log(host, port, certificate, user, password, localfile)
        Net::FTP.open(host, port: port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: certificate) do |ftp|
            ftp.login(user, password)
            lf = File.open(localfile)
            ftp.storbinary("STOR #{File.basename(localfile)}", lf, Net::FTP::DEFAULT_BLOCKSIZE)
        end
    end

    ### TESTS ###
    describe "#LogTransferServerTests" do

        before do
            spawn_server
        end

        after do
            # check testfile exists and deletes is if it does
        end
        
        it "tests connection to server" do
            Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @server.certfile_path) do |ftp|
                assert ftp.login("test.user", "test.password"), "FTP server doesn't connect."
            end
        end

        # it "tests password authentication" do
        #     spawn_server_with_password
        #     Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
        #         assert ftp.login("test.user", "password123"), "FTP server doesn't connect with authentication."
        #     end
        # end

        # it "tests file uploads to server" do
        #     spawn_and_upload_testfile
        #     assert File.exist?("#{@temp_dir}/testfile"), "Uploaded file doesn't exist."
        # end

        # it "tests upload of file that already exists" do
        #     spawn_and_upload_testfile
        #     assert_raises(Net::FTPPermError) {upload_testfile}
        # end

        # it "tests read function blocking of remote repository" do
        #     spawn_and_upload_testfile
        #     Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
        #         ftp.login("test.user", "")
        #         assert_raises(Net::FTPPermError) { ftp.get("#{@temp_dir}/testfile") }
        #     end
        # end

    end
end

