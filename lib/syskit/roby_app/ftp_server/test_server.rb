require "minitest/autorun"
require "minitest/spec"
require "tmpdir"
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

    describe "#initialize" do

        it "checks existence of ftp server" do

            Dir.mktmpdir do |temp_dir|
                server = Syskit::RobyApp::FtpServer::Server.new(temp_dir)
                server.run
                #FileUtils.touch File.expand_path('test.txt', temp_dir)
                puts server.port
                certificate = "/home/rbtmrcs/.local/share/autoproj/gems/ruby/2.5.0/gems/ftpd-2.1.0/insecure-test-cert.pem"
                upload_log("127.0.0.1", "5000", certificate, ENV["LOGNAME"], "", "test.txt")
                # assert (test, msg=nil)
                assert File.exist?("#{temp_dir}/test.txt") != nil
            end
        end

    end
end