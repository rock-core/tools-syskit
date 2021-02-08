# frozen_string_literal: true

require "orocos/test"
require "orogen"
require "syskit/roby_app/remote_processes"
require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::RemoteProcesses do
    attr_reader :server
    attr_reader :client
    attr_reader :root_loader
    attr_reader :temp_dir
    attr_reader :certificate
    attr_reader :user
    attr_reader :password
    attr_reader :log_transfer_server
    attr_reader :logfile

    class TestLogTransferServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        include Ftpd::InsecureCertificate

        attr_accessor :user, :password, :certfile_path

        def initialize(
            tgt_dir,
            user = "test.user",
            password = "password123",
            certfile_path = insecure_certfile_path
        )
            super
        end
    end

    def start_server
        @server = Syskit::RobyApp::RemoteProcesses::Server.new(
            Syskit::RobyApp::RemoteProcesses::Server::DEFAULT_OPTIONS,
            0
        )
        server.open

        @server_thread = Thread.new do
            server.listen
        end
    end

    def connect_to_server
        @root_loader = OroGen::Loaders::Aggregate.new
        OroGen::Loaders::RTT.setup_loader(root_loader)
        @client = Syskit::RobyApp::RemoteProcesses::Client.new(
            "localhost",
            server.port,
            :root_loader => root_loader
        )
    end

    def start_and_connect_to_server
        start_server
        connect_to_server
    end

    def spawn_log_transfer_server
        @temp_dir = Ftpd::TempDir.make
        @user = "test.user"
        @password = "password123"
        @log_transfer_server = TestLogTransferServer.new(@temp_dir, @user, @password)
    end

    before do
        @current_log_level = Syskit::RobyApp::RemoteProcesses::Server.logger.level
    end

    after do
        if @server_thread
            @server_thread.raise Interrupt
            @server_thread.join
        end
    end

    describe "#initialize" do
        it "registers the loader exactly once on the provided root loader" do
            start_server
            root_loader = OroGen::Loaders::Aggregate.new
            OroGen::Loaders::RTT.setup_loader(root_loader)
            client = Syskit::RobyApp::RemoteProcesses::Client.new(
                "localhost",
                server.port,
                :root_loader => root_loader
            )
            assert_equal [client.loader], root_loader.loaders
        end
    end

    describe "#upload_log_file" do
        before do
            start_and_connect_to_server
            spawn_log_transfer_server
            @logfile = Dir.pwd + "/" + "logfile.log"
            File.new(logfile, "w+")
        end

        after do
            File.delete(logfile)
        end

        it "uploads a log file" do
            client.upload_log_file("127.0.0.1", log_transfer_server.port, certificate, user, password, logfile)
            assert File.exist?("#{temp_dir}/logfile.log")
        end

        it "uploads a log file that already exists" do
            client.upload_log_file("127.0.0.1", log_transfer_server.port, certificate, user, password, logfile)
            assert_raises(Syskit::RobyApp::RemoteProcesses::Client::Failed) do
                client.upload_log_file("127.0.0.1", log_transfer_server.port, certificate, user, password, logfile)
            end
        end
    end
end
