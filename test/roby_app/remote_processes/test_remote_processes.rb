# frozen_string_literal: true

require "securerandom"
require "syskit/test/self"
require "syskit/roby_app/remote_processes"
require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::RemoteProcesses do
    attr_reader :server
    attr_reader :client
    attr_reader :root_loader

    class TestLogTransferServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        def insecure_certfile_path
            File.join(__dir__, "cert.pem")
        end

        def initialize(target_dir, user, password)
            @certfile_path = insecure_certfile_path
            super(target_dir, user, password, @certfile_path)
        end

        def certificate
            File.read(@certfile_path)
        end
    end

    def start_server
        @server = Syskit::RobyApp::RemoteProcesses::Server.new(@app, port: 0)
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
            :root_loader => root_loader)
        )
    end

    def start_and_connect_to_server
        start_server
        connect_to_server
    end

    before do
        @app = Roby::Application.new
        @app.log_dir = make_tmpdir
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
                "localhost",
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
            assert loader.available_projects.has_key?("orogen_syskit_tests")
        end

        it "knows about the available typekits" do
            assert loader.available_typekits.has_key?("orogen_syskit_tests")
        end

        it "knows about the available deployments" do
            assert loader.available_deployments.has_key?("syskit_tests_empty")
        end

        it "can load a remote project model" do
            assert loader.project_model_from_name("orogen_syskit_tests")
        end

        it "can load a remote typekit model" do
            assert loader.typekit_model_from_name("orogen_syskit_tests")
        end

        it "can load a remote deployment model" do
            assert loader.deployment_model_from_name("syskit_tests_empty")
        end
    end

    describe "#start" do
        before do
            start_and_connect_to_server
        end

        it "can start a process on the server synchronously" do
            process = client.start "syskit_tests_empty", "syskit_tests_empty",
                Hash["syskit_tests_empty" => "syskit_tests_empty"],
                :wait => true,
                :oro_logfile => nil, :output => "/dev/null"
            assert process.alive?
            assert Orocos.allow_blocking_calls { Orocos.get("syskit_tests_empty") }
        end

        it "raises if the deployment does not exist on the remote server" do
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "bla", "bla", Hash["sink" => "test"], :wait => true
            end
        end

        it "raises if the deployment does exist locally but not on the remote server" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "test"
            root_loader.register_deployment_model(deployment)
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "test", "test"
            end
        end

        it "uses the deployment model loaded on the root loader" do
            project    = OroGen::Spec::Project.new(root_loader)
            deployment = project.deployment "syskit_tests_empty"
            root_loader.register_deployment_model(deployment)
            process = client.start "syskit_tests_empty", "syskit_tests_empty", Hash.new, :wait => true,
                :oro_logfile => nil, :output => '/dev/null'
            assert_same deployment, process.model
        end
    end

    describe "stopping a remote process" do
        attr_reader :process
        before do
            start_and_connect_to_server
            @process = client.start "syskit_tests_empty", "syskit_tests_empty",
                Hash["syskit_tests_empty" => "syskit_tests_empty"],
                :wait => true,
                :oro_logfile => nil, :output => '/dev/null'
        end

        it "kills an already started process" do
            process.kill(true)
            assert_raises Orocos::NotFound do
                Orocos.allow_blocking_calls do
                    Orocos.get "syskit_tests_empty"
                end
            end
        end

        it "gets notified if a remote process dies" do
            Process.kill 'KILL', process.pid
            dead_processes = client.wait_termination
            assert dead_processes[process]
            assert !process.alive?
        end
    end

    describe "#upload_log_file" do
        before do
            start_and_connect_to_server
            @port, @certificate = spawn_log_transfer_server
            @logfile = File.join(make_tmpdir, "logfile.log")
            File.open(@logfile, "wb") do |f|
                f.write(SecureRandom.random_bytes(547)) # create random 5 MB file
            end
        end

        it "uploads a file" do
            client.upload_log_file(
                "127.0.0.1",
                @log_transfer_server.port, @log_transfer_server.certificate,
                @user, @password, @logfile
            )
            @server_thread.raise Interrupt
            @server_thread.join
            assert FileUtils.compare_file(@logfile, File.join(@temp_dir, "/logfile.log"))
        end

        it "refuses to overwrite an existing file" do
            FileUtils.touch File.join(@temp_dir, "logfile.log")
            assert_raises(Syskit::RobyApp::RemoteProcesses::Client::Failed) do
                client.upload_log_file(
                    "127.0.0.1",
                    @log_transfer_server.port, @log_transfer_server.certificate,
                    @user, @password, @logfile
                )
            end
        end

        def spawn_log_transfer_server
            @temp_dir = Ftpd::TempDir.make
            @user = "test.user"
            @password = "password123"
            @log_transfer_server = TestLogTransferServer.new(@temp_dir, @user, @password)
            @log_transfer_server.certificate
        end
    end
end
