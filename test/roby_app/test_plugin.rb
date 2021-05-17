# frozen_string_literal: true

require "syskit/test/self"
require "syskit/test/roby_app_helpers"
require "syskit/roby_app/remote_processes"

module Syskit
    module RobyApp
        describe Plugin do
            describe "remote model loading" do
                def create_process_server(name)
                    app = Roby::Application.new
                    loader = OroGen::Loaders::Files.new
                    OroGen::Loaders::RTT.setup_loader(loader)
                    loader.register_orogen_file(File.join(data_dir, "plugin_remote_model_loading.orogen"))

                    server = RemoteProcesses::Server.new(app, port: 0, loader: loader)
                    server.open

                    thread = Thread.new do
                        server.listen
                    end
                    client = Syskit.conf.connect_to_orocos_process_server(
                        name, "localhost", port: server.port
                    )
                    @process_servers << [name, thread, client]
                end

                attr_reader :server0, :server1
                before do
                    Syskit.conf.only_load_models = false
                    @process_servers = []
                    @server0 = create_process_server("server0")
                    @server1 = create_process_server("server1")
                end

                after do
                    capture_log(Syskit::RobyApp::RemoteProcesses::Server, :fatal) do
                        capture_log(Syskit::RobyApp::RemoteProcesses::Server, :warn) do
                            @process_servers.each do |name, thread, client|
                                client.close
                                Syskit.conf.remove_process_server(name)
                                thread.raise Interrupt
                                thread.join
                            end
                        end
                    end
                end

                it "registers a given deployment model only once" do
                    Roby.app.using_task_library "plugin_remote_model_loading"

                    m0 = Syskit.conf.use_deployment "plugin_remote_model_loading" => "m0", on: "server0"
                    m0 = m0.first
                    m1 = Syskit.conf.use_deployment "plugin_remote_model_loading" => "m1", on: "server1"
                    m1 = m1.first

                    assert_same m0.model.orogen_model, m1.model.orogen_model
                    assert_same OroGen::PluginRemoteModelLoading::Task.orogen_model,
                                m1.orogen_model.find_task_by_name("m1task").task_model
                end
            end
            describe "local process server startup" do
                before do
                    Syskit.conf.remove_process_server "localhost"
                end

                it "starts the process server on an ephemeral port and can connect to it" do
                    Plugin.start_local_process_server
                    client = Plugin.connect_to_local_process_server(Roby.app)
                    assert_same client, Syskit.conf.process_server_for("localhost")
                end
            end

            describe "configuration reloading" do
                before do
                    # The tests currently don't bother with completely cleaning
                    # up the plan to save time. This obviously assumes that each
                    # test gets a new plan object
                    #
                    # Use this new plan object for #app as well, since that's
                    # what we're testing here
                    app.reset_plan(plan)
                end
                it "reloads the configuration of all task context models" do
                    model = TaskContext.new_submodel
                    flexmock(model.configuration_manager).should_receive(:reload).once
                    app.syskit_reload_config
                end
                it "does not attempt to reload the configuration of specialized models" do
                    model = TaskContext.new_submodel
                    specialized = model.specialize
                    # The two share the same specialization manager. If
                    # #reload_config passes through the specialized models, #reload
                    # would be called twice
                    flexmock(specialized.configuration_manager).should_receive(:reload).once
                    app.syskit_reload_config
                end
                it "marks already configured components with changed configuration as needing to be reconfigured" do
                    model = TaskContext.new_submodel
                    task = syskit_stub_deploy_and_configure(model)
                    plan.add_permanent_task(deployment = task.execution_agent)
                    expect_execution { plan.unmark_mission_task(task) }
                        .garbage_collect(true)
                        .to { finalize task }
                    # NOTE: we need to mock the configuration manager AFTER the
                    # model stub, as stubbing protects the original manager
                    flexmock(model.configuration_manager).should_receive(:reload).once
                                                         .and_return(["default"])
                    flexmock(app).should_receive(:notify)
                                 .with("syskit", "INFO", "task #{task.orocos_name} needs reconfiguration").once
                    app.syskit_reload_config
                    assert_equal [task.orocos_name], deployment.pending_reconfigurations
                    assert_equal [[task.orocos_name], []],
                                 app.syskit_pending_reloaded_configurations
                end
                it "announces specifically if running tasks have had their configuration changed" do
                    model = TaskContext.new_submodel
                    task = syskit_stub_deploy_and_configure(model)
                    deployment = task.execution_agent
                    # NOTE: we need to mock the configuration manager AFTER the
                    # model stub, as stubbing protects the original manager
                    flexmock(model.configuration_manager).should_receive(:reload).once
                                                         .and_return(["default"])
                    flexmock(app).should_receive(:notify)
                                 .with("syskit", "INFO", "task #{task.orocos_name} needs reconfiguration").once
                    flexmock(app).should_receive(:notify)
                                 .with("syskit", "INFO", "1 running tasks configuration changed. In the shell, use 'redeploy' to trigger reconfiguration.").once
                    app.syskit_reload_config
                    assert task.needs_reconfiguration?
                    assert_equal [task.orocos_name], deployment.pending_reconfigurations
                    assert_equal [[task.orocos_name], [task.orocos_name]],
                                 app.syskit_pending_reloaded_configurations
                end
                it "ignores models that have never been configured" do
                    model = TaskContext.new_submodel
                    task = syskit_stub_and_deploy(model)
                    deployment = task.execution_agent
                    flexmock(model.configuration_manager).should_receive(:reload).once
                                                         .and_return(["default"])
                    app.syskit_reload_config
                    refute task.needs_reconfiguration?
                    assert_equal [], deployment.pending_reconfigurations
                    assert_equal [[], []],
                                 app.syskit_pending_reloaded_configurations
                end
                it "does not redeploy the network" do
                    model = TaskContext.new_submodel
                    task = syskit_stub_deploy_and_configure(model)
                    flexmock(model.configuration_manager).should_receive(:reload).once
                                                         .and_return(["default"])
                    flexmock(Runtime).should_receive(:apply_requirement_modifications).never
                    app.syskit_reload_config
                end
            end

            describe "model reloading" do
                include Test::RobyAppHelpers

                def perform_app_assertion(result)
                    success, msg = *result
                    assert(success, msg || "")
                end

                before do
                    app_helpers_source_dir File.join(__dir__, "app")
                    gen_app
                end

                it "reloads and redefines orogen deployments" do
                    copy_into_app "models/pack/orogen/reload-1.orogen",
                                  "models/pack/orogen/reload.orogen"
                    copy_into_app "config/robots/reload_orogen.rb",
                                  "config/robots/default.rb"
                    pid = roby_app_spawn "run", silent: true
                    interface = assert_roby_app_is_running(pid)
                    copy_into_app "models/pack/orogen/reload-2.orogen",
                                  "models/pack/orogen/reload.orogen"
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                    interface.reload_models
                    perform_app_assertion interface.unit_tests.orogen_model_reloaded?
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                end

                it "reloads and redefines ruby tasks" do
                    copy_into_app "models/compositions/reload_ruby_task-1.rb",
                                  "models/compositions/reload_ruby_task.rb"
                    copy_into_app "config/robots/reload_ruby_task.rb",
                                  "config/robots/default.rb"
                    pid = roby_app_spawn "run", silent: true
                    interface = assert_roby_app_is_running(pid)
                    copy_into_app "models/compositions/reload_ruby_task-2.rb",
                                  "models/compositions/reload_ruby_task.rb"
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                    interface.reload_models
                    perform_app_assertion interface.unit_tests.orogen_model_reloaded?
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                end

                it "reloads and redefines unmanaged tasks" do
                    copy_into_app "models/pack/orogen/reload-1.orogen",
                                  "models/pack/orogen/reload.orogen"
                    copy_into_app "config/robots/reload_unmanaged_task.rb",
                                  "config/robots/default.rb"
                    pid = roby_app_spawn "run", silent: true
                    interface = assert_roby_app_is_running(pid)
                    copy_into_app "models/pack/orogen/reload-2.orogen",
                                  "models/pack/orogen/reload.orogen"
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                    interface.reload_models
                    perform_app_assertion interface.unit_tests.orogen_model_reloaded?
                    perform_app_assertion interface.unit_tests.orogen_deployment_exists?
                end
            end

            describe "Local Log Transfer Server" do

                def pre_config_server
                    @app = Roby::Application.new
                    @app.log_dir = make_tmpdir
                    @current_log_level = RemoteProcesses::Server.logger.level
                    RemoteProcesses::Server.logger.level = Logger::FATAL + 1
                end

                def start_server
                    raise "server already started" if @server
                    @server = RemoteProcesses::Server.new(@app, port: 0)
                    server.open
                    @server_thread = Thread.new { server.listen }
                end

                def connect_to_server
                    @root_loader = OroGen::Loaders::Aggregate.new
                    OroGen::Loaders::RTT.setup_loader(root_loader)
                    @client = RemoteProcesses::Client.new(
                        "localhost",
                        server.port,
                        root_loader: root_loader
                    )
                end
            
                def start_and_connect_to_server
                    start_server
                    connect_to_server
                end

                def start_process_server(name, host)
                    @ps_log_dir = make_tmpdir
                    @client.create_log_dir(
                        @ps_log_dir, Roby.app.time_tag,
                        { "parent" => Roby.app.app_metadata }
                    )
                    Configuration.register_process_server(name, @client, log_dir, host_id: name)
                end

                def create_process_server(name)
                    # Clearing Orocos load
                    Orocos.clear
                    app = Roby::Application.new
                    loader = OroGen::Loaders::Files.new
                    OroGen::Loaders::RTT.setup_loader(loader)
                    loader.register_orogen_file(File.join(data_dir, "plugin_remote_model_loading.orogen"))

                    server = RemoteProcesses::Server.new(app, port: 0, loader: loader)
                    server.open

                    thread = Thread.new do
                        server.listen
                    end

                    client = Syskit.conf.connect_to_orocos_process_server(
                        name, "localhost", port: server.port
                    )

                    @process_servers << [name, thread, client]
                    
                    @ps_log_dir = make_tmpdir
                    client.create_log_dir(
                        @ps_log_dir, Roby.app.time_tag,
                        { "parent" => Roby.app.app_metadata }
                    )
                end

                def close_process_servers
                    @process_servers.each do |name, thread, client|
                        client.close
                        Syskit.conf.remove_process_server(name)
                        thread.raise Interrupt
                        thread.join
                    end
                end
                
                def create_test_file(ps_log_dir)
                    logfile = File.join(ps_log_dir, "logfile.log")
                    File.open(logfile, "wb") do |f|
                        # create random 5 MB file
                        f.write(SecureRandom.random_bytes(547))
                    end
                    logfile
                end

                def start_local_transfer_server(tmp_root_ca)
                    @tmp_server_dir = make_tmpdir
                    @user = "test.user"
                    @password = "password123"
                    @log_transfer_server = LogTransferIntegration::LocalLogTransferServer.new(
                        @tmp_server_dir, @user, @password,
                        tmp_root_ca.signed_certificate
                    )
                end

                before do
                    # Initializing Process Server
                    # # pre_config_server
                    # # start_and_connect_to_server
                    # # start_process_server("test_ps", "localhost")
                    Syskit.conf.only_load_models = false
                    @process_servers = []
                    @test_ps = create_process_server("test_ps")
                    # Initilizing Log Transfer Server
                    @test_root_ca = LogTransferIntegration::TmpRootCA.new
                    start_local_transfer_server(@test_root_ca)
                end

                after do
                    @log_transfer_server.stop
                    @log_transfer_server.join
                    close_process_servers
                end

                it "uploads file from Process Server" do
                    @ps_logfile = create_test_file(@ps_log_dir)
                    path = File.join(@tmp_server_dir, "logfile.log")
                    refute File.exist?(path)
                    Plugin.send_file_transfer_command("test_ps", @ps_logfile)
                    assert_equal File.read(path), File.read(@ps_logfile)
                end

            end

        end
    end
end
