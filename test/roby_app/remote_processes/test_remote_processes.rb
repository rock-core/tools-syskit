# frozen_string_literal: true

require "securerandom"
require "syskit/test/self"
require "syskit/roby_app/remote_processes"
require "syskit/roby_app/remote_processes/server"
require "syskit/roby_app/log_transfer_server"

describe Syskit::RobyApp::RemoteProcesses do
    attr_reader :server
    attr_reader :client
    attr_reader :root_loader

    class TestLogTransferServer < Syskit::RobyApp::LogTransferServer::SpawnServer
        attr_reader :certfile_path

        def initialize(target_dir, user, password)
            @certfile_path = File.join(__dir__, "cert.crt")
            private_cert = File.join(__dir__, "cert-private.crt")
            super(target_dir, user, password, private_cert)
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
            root_loader: root_loader
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
                root_loader: root_loader
            )
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
            assert loader.available_projects.key?("orogen_syskit_tests")
        end

        it "knows about the available typekits" do
            assert loader.available_typekits.key?("orogen_syskit_tests")
        end

        it "knows about the available deployments" do
            assert loader.available_deployments.key?("syskit_tests_empty")
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
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                wait: true, oro_logfile: nil, output: "/dev/null"
            )
            assert process.alive?
            assert(Orocos.allow_blocking_calls { Orocos.get("syskit_tests_empty") })
        end

        it "raises if the deployment does not exist on the remote server" do
            assert_raises(OroGen::DeploymentModelNotFound) do
                client.start "bla", "bla", Hash["sink" => "test"], wait: true
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
            process = client.start(
                "syskit_tests_empty", "syskit_tests_empty", {},
                wait: true, oro_logfile: nil, output: "/dev/null"
            )
            assert_same deployment, process.model
        end
    end

    describe "stopping a remote process" do
        attr_reader :process
        before do
            start_and_connect_to_server
            @process = client.start(
                "syskit_tests_empty", "syskit_tests_empty",
                { "syskit_tests_empty" => "syskit_tests_empty" },
                wait: true, oro_logfile: nil, output: "/dev/null"
            )
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
            Process.kill "KILL", process.pid
            dead_processes = client.wait_termination
            assert dead_processes[process]
            assert !process.alive?
        end
    end

    describe "#log_upload_file" do
        before do
            start_and_connect_to_server
            @port, @certificate = spawn_log_transfer_server
            @logfile = File.join(make_tmpdir, "logfile.log")
            File.open(@logfile, "wb") do |f|
                f.write(SecureRandom.random_bytes(547)) # create random 5 MB file
            end
        end

        after do
            if @server_thread&.alive?
                @server_thread.raise Interrupt
                @server_thread.join
            end
        end

        it "uploads a file" do
            path = File.join(@temp_serverdir, "logfile.log")
            refute File.exist?(path)
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, @password, @logfile
            )
            assert_upload_succeeds
            assert_equal File.read(path), File.read(@logfile)
        end

        it "rejects a wrong user" do
            client.log_upload_file(
                "localhost", @port, @certificate,
                "somethingsomething", @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/Login incorrect/, result.message)
        end

        it "rejects a wrong password" do
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, "somethingsomething", @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/Login incorrect/, result.message)
        end

        it "refuses to overwrite an existing file" do
            FileUtils.touch File.join(@temp_serverdir, "logfile.log")
            client.log_upload_file(
                "localhost", @port, @certificate,
                @user, @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/File already exists/, result.message)
        end

        it "fails on an invalid certificate" do
            certfile_path = File.join(__dir__, "invalid-cert.crt")
            client.log_upload_file(
                "localhost", @port, File.read(certfile_path),
                @user, @password, @logfile
            )

            state = wait_for_upload_completion
            result = state.each_result.first
            assert_equal @logfile, result.file
            refute result.success?
            assert_match(/certificate verify failed/, result.message)
        end

        def spawn_log_transfer_server
            @temp_serverdir = make_tmpdir
            @user = "test.user"
            @password = "password123"
            @log_transfer_server = TestLogTransferServer.new(
                @temp_serverdir, @user, @password
            )
            [@log_transfer_server.port, File.read(@log_transfer_server.certfile_path)]
        end

        def wait_for_upload_completion(poll_period: 0.01, timeout: 1)
            deadline = Time.now + timeout
            loop do
                if Time.now > deadline
                    flunk("timed out while waiting for upload completion")
                end

                state = client.log_upload_state
                return state if state.pending_count == 0

                sleep poll_period
            end
        end

        def assert_upload_succeeds
            wait_for_upload_completion.each_result do |r|
                flunk("upload failed: #{r.message}") unless r.success?
            end
        end
    end
end
