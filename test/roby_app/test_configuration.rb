# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/process_server"

describe Syskit::RobyApp::Configuration do
    describe "#use_deployment" do
        attr_reader :task_m, :conf
        before do
            @task_m = Syskit::TaskContext.new_submodel(name: "test::Task")
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            conf.register_process_server("localhost", Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
            conf.register_process_server("test", Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        def stub_deployment(name)
            task_m = @task_m
            Syskit::Deployment.new_submodel(name: name) do
                task("task", task_m.orogen_model)
            end
        end

        it "accepts a task model-to-name mapping" do
            deployment_m = stub_deployment "test"
            default_deployment_name = OroGen::Spec::Project
                                      .default_deployment_name("test::Task")
            flexmock(@conf.app.default_loader)
                .should_receive(:deployment_model_from_name)
                .with(default_deployment_name)
                .and_return(deployment_m.orogen_model)
            configured_deployments = conf.use_deployment task_m => "task"
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            assert_equal task_m.orogen_model, configured_d.model.tasks.first.task_model
        end
    end

    describe "#use_ruby_tasks" do
        before do
            @task_m = Syskit::RubyTaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server("ruby_tasks",
                                          Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        it "defines a deployment for a given ruby task context model" do
            configured_deployments = @conf.use_ruby_tasks({ @task_m => "task" })
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            assert_equal @task_m.deployment_model, configured_d.model
        end
    end

    describe "#use_unmanaged_task" do
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server("unmanaged_tasks",
                                          Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end
        it "defines a configured deployment from a task model and name" do
            configured_deployments = @conf.use_unmanaged_task @task_m => "name"
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            deployed_task = configured_d.each_orogen_deployed_task_context_model
                                        .first
            assert_equal "name", deployed_task.name
            assert_equal @task_m.orogen_model, deployed_task.task_model
        end
    end

    describe "#connect_to_orocos_process_server" do
        before do
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @mock_process = flexmock(pid: 20)
            @mock_process.should_receive(:spawn).by_default
            @mock_process.should_receive(:kill).by_default
            @mock_process.should_receive(:dead!).by_default
            @available_project_names = []
            @available_typekit_names = []
            @available_deployment_names = ["deployment"]

            set_log_level ::Robot, Logger::FATAL + 1
            set_log_level Orocos::RemoteProcesses::Server, Logger::FATAL + 1
        end

        after do
            process_server_stop if @server_thread
        end

        describe "process startup" do
            attr_reader :ruby_task, :deployment_m
            before do
                @ruby_task = ruby_task = Orocos.allow_blocking_calls do
                    Orocos::RubyTasks::TaskContext.new "remote-task"
                end
                @deployment_m = Syskit::Deployment.new_submodel do
                    task "name", ruby_task.model
                end
                server = process_server_create
                server.should_receive(:start_process)
                      .and_return(@mock_process)
            end

            after do
                @ruby_task.dispose
            end

            it "starts the process and reports its PID" do
                process_server_start

                client = @conf.connect_to_orocos_process_server(
                    "test-remote", "localhost",
                    port: process_server_port
                )

                process = client.start "deployment", deployment_m.orogen_model
                assert_equal 20, process.pid
            end

            it "allows to specify the name service used to resolve the process' task" do
                process_server_start

                name_service = Orocos::Local::NameService.new
                name_service.register ruby_task, "resolved-remote-name"
                client = @conf.connect_to_orocos_process_server(
                    "test-remote", "localhost",
                    port: process_server_port,
                    name_service: name_service
                )

                process = client.start(
                    "deployment", deployment_m.orogen_model,
                    { "name" => "resolved-remote-name" }
                )
                tasks = process.resolve_all_tasks
                assert_equal({ "resolved-remote-name" => ruby_task }, tasks)
            end
        end

        def process_server_create
            @server_loader = OroGen::Loaders::Base.new
            flexmock(@server_loader)
            @server_loader.should_receive(:each_available_typekit_name)
                          .explicitly
                          .and_return { @available_typekit_names }
            @server_loader.should_receive(:each_available_deployment_name)
                          .explicitly
                          .and_return { @available_deployment_names }
            @server_loader.should_receive(:each_available_project_name)
                          .and_return { @available_project_names }

            @server = Syskit::RobyApp::ProcessServer.new(
                Roby.app, port: 0, loader: @server_loader
            )
            flexmock(@server)
        end

        def process_server_start
            @server.open
            @server_thread = Thread.new do
                @server.listen
            end
        end

        def process_server_port
            @server.port
        end

        def process_server_stop
            @server_thread.raise Interrupt
            @server_thread.join
            @server = nil
            @server_thread = nil
        end
    end
end
