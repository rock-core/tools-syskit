# frozen_string_literal: true

require "minitest/autorun"

require "ftpd"
require "net/ftp"

require "syskit/roby_app/ftp_server"

class FtpServerTest < Minitest::Test
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

    def upload_log(host, port, certificate, user, password, localfile)
        Net::FTP.open(host, port: port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: certificate) do |ftp|
            ftp.login(user, password)
            lf = File.open(localfile)
            ftp.storbinary("STOR #{File.basename(localfile)}", lf, Net::FTP::DEFAULT_BLOCKSIZE)
        end
    end

    def test_connects_to_server
        spawn_server
        Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
            assert ftp.login("test.user", ""), "FTP server doesn't connect."
        end
    end

    def test_password_authentication
        spawn_server_with_password
        Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
            assert ftp.login("test.user", "password123"), "FTP server doesn't connect with authentication."
        end
    end

    def test_uploads_file_to_server
        spawn_server
        File.new("testfile", "w+")
        upload_log("127.0.0.1", @server.port, @certificate, "test.user", "", "testfile")
        File.delete("testfile")
        assert File.exist?("#{@temp_dir}/testfile"), "Uploaded file doesn't exist."
    end

    def test_cant_upload_file_that_already_exists
        spawn_server
        File.new("testfile", "w+")
        upload_log("127.0.0.1", @server.port, @certificate, "test.user", "", "testfile")
        assert_raises(Net::FTPPermError) {upload_log("127.0.0.1", @server.port, @certificate, "test.user", "", "testfile")}
        File.delete("testfile")
        # "Can't upload: File already exists"
        # Ftpd::PermanentFileSystemError
    end

    # def test_cant_read_from_remote_repository
    # end
end

