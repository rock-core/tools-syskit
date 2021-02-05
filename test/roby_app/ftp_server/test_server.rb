# frozen_string_literal: true

require "minitest/autorun"
require "minitest/spec"

require "ftpd"
require "net/ftp"

require "syskit/roby_app/ftp_server"

describe Syskit::RobyApp::FtpServer::Server do
    
    ### AUXILIARY FUNCTIONS ###
    def spawn_server
        @temp_dir = Ftpd::TempDir.make
        @server = Syskit::RobyApp::FtpServer::Server.new(@temp_dir, user: "test.user")
        @certificate = "/home/#{ENV['LOGNAME']}/.local/share/autoproj/gems/ruby/2.5.0/gems/ftpd-2.1.0/insecure-test-cert.pem"
        # @certificate = Ftpd::InsecureCertificate.insecure_certfile_path
    end

    def spawn_server_with_password
        @temp_dir = Ftpd::TempDir.make
        @server = Syskit::RobyApp::FtpServer::Server.new(@temp_dir, user: "test.user", password: "password123")
        @certificate = "/home/#{ENV['LOGNAME']}/.local/share/autoproj/gems/ruby/2.5.0/gems/ftpd-2.1.0/insecure-test-cert.pem"
    end

    def upload_testfile
        File.new("testfile", "w+")
        upload_log("127.0.0.1", @server.port, @certificate, "test.user", "", "testfile")
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
        
        it "tests connection to server" do
            spawn_server
            Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
                assert ftp.login("test.user", ""), "FTP server doesn't connect."
            end
        end

        it "tests password authentication" do
            spawn_server_with_password
            Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
                assert ftp.login("test.user", "password123"), "FTP server doesn't connect with authentication."
            end
        end

        it "tests file uploads to server" do
            spawn_and_upload_testfile
            File.delete("testfile") if File.exist?("testfile") # delete in local directory
            assert File.exist?("#{@temp_dir}/testfile"), "Uploaded file doesn't exist."
        end

        it "tests upload of file that already exists" do
            spawn_and_upload_testfile
            File.delete("testfile") if File.exist?("testfile") # delete in local directory
            assert_raises(Net::FTPPermError) {upload_testfile}
        end

        it "tests read function blocking of remote repository" do
            spawn_and_upload_testfile
            File.delete("testfile") if File.exist?("testfile") # delete in local directory
            Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
                ftp.login("test.user", "")
                assert_raises(Net::FTPPermError) { ftp.get("#{@temp_dir}/testfile") }
            end
        end

    end
end

