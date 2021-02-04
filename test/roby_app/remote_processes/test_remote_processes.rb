# frozen_string_literal: true

require "orocos/test"
#require 'minitest/autorun'
#require 'minitest/spec'
#require 'flexmock/minitest'
#require "orogen"
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

        it "knows about the available projects" do
            assert loader.available_projects.has_key?('simple_sink')
        end

        it "knows about the available typekits" do
            assert loader.available_typekits.has_key?('simple_sink')
        end

        it "knows about the available deployments" do
            assert loader.available_deployments.has_key?('simple_sink')
        end

        it "can load a remote project model" do
            assert loader.project_model_from_name('simple_sink')
        end

        it "can load a remote typekit model" do
            assert loader.typekit_model_from_name('simple_sink')
        end

        it "can load a remote deployment model" do
            assert loader.deployment_model_from_name('simple_sink')
        end
    end

    describe "#start" do
        before do
            start_and_connect_to_server
        end

        it "can start a process on the server synchronously" do
            process = client.start "simple_sink", "simple_sink",
                Hash["simple_sink_sink" => "test"],
                :wait => true,
                :oro_logfile => nil, :output => '/dev/null'
            assert process.alive?
            assert Orocos.get('test')
        end

        it "raises if the deployment does not exist on the remote server" do
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "bla", "bla", Hash["sink" => "test"], :wait => true
            end
        end

        it "raises if the deployment does exist locally but not on the remote server" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment 'test'
            root_loader.register_deployment_model(deployment)
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "test", "test"
            end
        end

        it "uses the deployment model loaded on the root loader" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment 'simple_sink'
            root_loader.register_deployment_model(deployment)
            process = client.start "simple_sink", "simple_sink", Hash.new, :wait => true,
                :oro_logfile => nil, :output => '/dev/null'
            assert_same deployment, process.model
        end
    end

    describe "stopping a remote process" do
        attr_reader :process
        before do
            start_and_connect_to_server
            @process = client.start "simple_sink", "simple_sink",
                Hash["simple_sink_sink" => "test"],
                :wait => true,
                :oro_logfile => nil, :output => '/dev/null'
        end

        it "kills an already started process" do
            process.kill(true)
            assert_raises Orocos::NotFound do
                Orocos.get "simple_sink_sink"
            end
        end

        it "gets notified if a remote process dies" do
            Process.kill 'KILL', process.pid
            dead_processes = client.wait_termination
            assert dead_processes[process]
            assert !process.alive?
        end
    end
end
