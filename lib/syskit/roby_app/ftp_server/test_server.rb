# frozen_string_literal: true

require "minitest/autorun"
require "minitest/spec"

require "ftpd"
require "net/ftp"

require "syskit/roby_app/ftp_server"

describe Syskit::RobyApp::FtpServer do
    def upload_log(host, port, certificate, user, password, localfile)
        Net::FTP.open(host, port: port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: certificate) do |ftp|
            ftp.login(user, password)
            lf = File.open(localfile)
            ftp.storbinary("STOR #{File.basename(localfile)}", lf, Net::FTP::DEFAULT_BLOCKSIZE)
        end
    end

    def spawn_server
        @temp_dir = Ftpd::TempDir.make
        @server = Syskit::RobyApp::FtpServer::Server.new(@temp_dir)
        @certificate = "/home/#{ENV['LOGNAME']}/.local/share/autoproj/gems/ruby/2.5.0/gems/ftpd-2.1.0/insecure-test-cert.pem"
        # @certificate = Ftpd::InsecureCertificate.insecure_certfile_path
    end

    describe "#initialize" do
        it "checks ftp server connection" do
            spawn_server
            Net::FTP.open("127.0.0.1", port: @server.port, verify_mode: OpenSSL::SSL::VERIFY_PEER, ca_file: @certificate) do |ftp|
                assert ftp.login(ENV["LOGNAME"] || "test", ""), msg = "FTP server doesn't connect."
            end
        end

        it "checks ftp server upload" do
            File.new("testfile", "w+")
            upload_log("127.0.0.1", @server.port, @certificate, ENV["LOGNAME"] || "test", "", "testfile")            
            assert File.exist?("#{@temp_dir}/testfile"), msg = "Uploaded file doesn't exist."
        end

    end
end

