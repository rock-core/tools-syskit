# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/remote_processes"

describe Syskit::RobyApp::Configuration do
    describe "#use_deployment" do
        attr_reader :task_m, :conf
        before do
            @task_m = Syskit::TaskContext.new_submodel(name: "test::Task")
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            conf.register_process_server("localhost", Syskit::RobyApp::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
            conf.register_process_server("test", Syskit::RobyApp::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        def stub_deployment(name)
            task_m = @task_m
            Syskit::Deployment.new_submodel(name: name) do
                task("task", task_m)
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
                                          Syskit::RobyApp::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
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
                                          Syskit::RobyApp::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
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
            set_log_level Syskit::RobyApp::RemoteProcesses::Server, Logger::FATAL + 1
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
                task_m = Syskit::TaskContext.new_submodel(orogen_model: ruby_task.model)
                @deployment_m = Syskit::Deployment.new_submodel do
                    task "name", task_m
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

            it "marks the process server as supporting log transfer" do
                process_server_start
                @conf.connect_to_orocos_process_server(
                    "test-remote", "localhost",
                    port: process_server_port
                )
                config = @conf.process_server_config_for("test-remote")
                assert config.supports_log_transfer?
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

            @server = Syskit::RobyApp::RemoteProcesses::Server.new(
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

    describe "log transfer" do
        before do
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @log_transfer = @conf.log_transfer
        end

        describe "#max_upload_rate_for" do
            it "returns the default rate if the max_upload_rates hash "\
               "has no entry for the given server" do
                default = flexmock
                @log_transfer.default_max_upload_rate = default
                assert_equal default, @log_transfer.max_upload_rate_for("test")
            end

            it "lets the caller set a different default" do
                default = flexmock
                assert_equal default,
                             @log_transfer.max_upload_rate_for("test", default: default)
            end

            it "finds a process server by name" do
                actual = flexmock
                @log_transfer.max_upload_rates["test"] = actual
                assert_equal actual, @log_transfer.max_upload_rate_for("test")
            end

            it "finds a process server by object" do
                actual = flexmock
                @log_transfer.max_upload_rates["test"] = actual
                assert_equal actual, @log_transfer.max_upload_rate_for(flexmock(name: "test"))
            end
        end
    end
end
