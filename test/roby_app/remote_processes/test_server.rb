# frozen_string_literal: true

require "orocos/test"
#require 'minitest/autorun'
#require 'minitest/spec'
#require 'flexmock/minitest'
require "orogen"
require "syskit/roby_app/remote_processes"

describe Syskit::RobyApp::RemoteProcesses do
    attr_reader :server, :client, :root_loader

    def start_server
        @server = Syskit::RobyApp::RemoteProcesses::Server.new(
            Syskit::RobyApp::RemoteProcesses::Server::DEFAULT_OPTIONS,
            0)
        server.open

        @server_thread = Thread.new do
            server.listen
        end
    end

    def connect_to_server
        @root_loader = OroGen::Loaders::Aggregate.new
        OroGen::Loaders::RTT.setup_loader(root_loader)
        @client = Syskit::RobyApp::RemoteProcesses::Client.new(
            'localhost',
            server.port,
            :root_loader => root_loader)
    end

    def start_and_connect_to_server
        start_server
        connect_to_server
    end

    before do
        @current_log_level = Syskit::RobyApp::RemoteProcesses::Server.logger.level
        Syskit::RobyApp::RemoteProcesses::Server.logger.level = Logger::FATAL + 1
    end

    after do
        if @server_thread
            @server_thread.raise Interrupt
            @server_thread.join
        end

        if @current_log_level
            Syskit::RobyApp::RemoteProcesses::Server.logger.level = @current_log_level
        end
    end

    describe "#initialize" do
        it "registers the loader exactly once on the provided root loader" do
            start_server
            root_loader = OroGen::Loaders::Aggregate.new
            OroGen::Loaders::RTT.setup_loader(root_loader)
            client = Syskit::RobyApp::RemoteProcesses::Client.new(
                'localhost',
                server.port,
                :root_loader => root_loader)
            assert_equal [client.loader], root_loader.loaders
        end
    end

    describe "#pid" do
        before do
            start_and_connect_to_server
        end

        it "returns the process server's PID" do
            assert_equal Process.pid, client.server_pid
        end
    end

    describe "#loader" do
        attr_reader :loader
        before do
            start_and_connect_to_server
            @loader = client.loader
        end
    end

    #????
    describe "#start" do
        before do
            start_and_connect_to_server
        end
    end

    describe "#command_upload_log" do
        before do
            start_and_connect_to_server
        end

        it "uploads log file" do
            client = Syskit::RobyApp::RemoteProcesses::Client.new(
                'localhost',
                server.port)
            certificate = "/home/#{ENV['LOGNAME']}/.local/share/autoproj/gems/ruby/2.5.0/gems/ftpd-2.1.0/insecure-test-cert.pem"
            client.upload_log_file("127.0.0.1", 41475, certificate, "mateus", "123", "/home/mateus/logfile.log")
            assert_equal 1, 1
        end
    end
end
