# frozen_string_literal: true

require "syskit/test/self"
require "roby/interface/rest"
require "rack/test"
require "syskit/roby_app/rest_api"

module Syskit
    module RobyApp
        describe REST_API do
            # Bypass Roby's own test setup
            def setup
                @roby_app = Roby::Application.new
                @roby_interface = Roby::Interface::Interface.new(@roby_app)
            end

            def teardown; end

            include Rack::Test::Methods

            def app
                Roby::Interface::REST::Server
                    .attach_api_to_interface(REST_API, @roby_interface)
            end

            def get_json(*args)
                response = get(*args)
                assert response.ok?, response.body
                JSON.parse(response.body)
            end

            def post_json(*args)
                response = post(*args)
                assert_equal 201, response.status,
                             "POST failed with code #{response.status}: #{response.body}"
                JSON.parse(response.body)
            end

            describe "/deployments" do
                describe "/available" do
                    before do
                        flexmock(@roby_app.default_pkgconfig_loader)
                            .should_receive(:each_available_deployed_task)
                            .by_default
                    end
                    def setup_deployed_task(deployed_task)
                        flexmock(@roby_app.default_pkgconfig_loader)
                            .should_receive(:each_available_deployed_task)
                            .and_iterates([deployed_task])
                    end

                    it "returns an empty list if there are no deployments" do
                        result = get_json "/deployments/available"
                        assert_equal Hash["deployments" => []], result
                    end
                    it "returns the list of available deployments" do
                        setup_deployed_task(OroGen::Loaders::PkgConfig::AvailableDeployedTask.new(
                                                "test_task", "test_deployment", "test::Task", "test"
                                            ))
                        result = get_json "/deployments/available"
                        expected = Hash[
                            "name" => "test_deployment",
                            "project_name" => "test",
                            "tasks" => Array[
                                Hash["task_name" => "test_task", "task_model_name" => "test::Task"]
                            ],
                            "default_deployment_for" => nil,
                            "default_logger" => nil
                        ]
                        assert_equal [expected], result["deployments"]
                    end
                    it "identifies default deployments and reports them" do
                        setup_deployed_task(OroGen::Loaders::PkgConfig::AvailableDeployedTask.new(
                                                "orogen_default_test__Task", "orogen_default_test__Task", "test::Task", "test"
                                            ))
                        result = get_json "/deployments/available"
                        assert_equal "test::Task", result["deployments"][0]["default_deployment_for"]
                    end
                    it "identifies default loggers and reports them" do
                        setup_deployed_task(OroGen::Loaders::PkgConfig::AvailableDeployedTask.new(
                                                "test_deployment_Logger", "test_deployment", "logger::Logger", "test"
                                            ))
                        result = get_json "/deployments/available"
                        assert_equal "test_deployment_Logger", result["deployments"][0]["default_logger"]
                    end
                    it "uses the model name to identify default loggers" do
                        setup_deployed_task(OroGen::Loaders::PkgConfig::AvailableDeployedTask.new(
                                                "test_deployment_Logger", "test_deployment", "something::Else", "test"
                                            ))
                        result = get_json "/deployments/available"
                        assert_nil result["deployments"][0]["default_logger"]
                    end
                    it "uses the task name pattern to identify default loggers" do
                        setup_deployed_task(OroGen::Loaders::PkgConfig::AvailableDeployedTask.new(
                                                "custom_logger", "test_deployment", "logger::Logger", "test"
                                            ))
                        result = get_json "/deployments/available"
                        assert_nil result["deployments"][0]["default_logger"]
                    end
                end

                describe "/registered" do
                    before do
                        @configured_deployments = []
                        flexmock(Syskit.conf.deployment_group).should_receive(:each_configured_deployment)
                                                              .and_return { @configured_deployments }
                        Syskit.conf.register_process_server(
                            "localhost",
                            flexmock(:on, Syskit::RobyApp::RemoteProcesses::Client)
                        )
                        Syskit.conf.register_process_server("unmanaged_tasks",
                                                            flexmock(:on, UnmanagedTasksManager))
                        Syskit.conf.register_process_server("something_else",
                                                            flexmock)

                        orogen_task_m = OroGen::Spec::TaskContext.new(
                            Roby.app.default_orogen_project, "test::Task"
                        )
                        @syskit_task_m = Syskit::TaskContext.define_from_orogen(
                            orogen_task_m
                        )
                        orogen_deployment_m = OroGen::Spec::Deployment.new(
                            nil, "test_deployment"
                        )
                        orogen_deployment_m.task "test_task", orogen_task_m
                        @deployment_m = Syskit::Deployment.define_from_orogen(orogen_deployment_m)
                    end
                    after do
                        @syskit_task_m.clear_model
                        Syskit.conf.remove_process_server("unmanaged_tasks")
                        Syskit.conf.remove_process_server("localhost")
                        Syskit.conf.remove_process_server("something_else")
                    end
                    it "returns empty if there are no deployments registered" do
                        assert_equal Hash["registered_deployments" => []],
                                     get_json("/deployments/registered")
                    end
                    it "returns the deployments as registered in Syskit" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "localhost", @deployment_m,
                            Hash["test_task" => "mapped_test_task"], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        expected = Hash[
                            "id" => configured_deployment.object_id,
                            "deployment_name" => "test_deployment",
                            "on" => "localhost",
                            "mappings" => Hash["test_task" => "mapped_test_task"],
                            "tasks" => [
                                Hash["task_name" => "mapped_test_task",
                                     "task_model_name" => "test::Task"]
                            ],
                            "type" => "orocos",
                            "created" => false
                        ]
                        assert_equal Hash["registered_deployments" => [expected]],
                                     get_json("/deployments/registered")
                    end

                    it "returns a deployment type of 'orocos' for an orocos remote process server" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "localhost", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        assert_equal "orocos",
                                     get_json("/deployments/registered")["registered_deployments"][0]["type"]
                    end

                    it "returns a deployment type of 'unmanaged' for an unmanaged task" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "unmanaged_tasks", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        assert_equal "unmanaged",
                                     get_json("/deployments/registered")["registered_deployments"][0]["type"]
                    end

                    it "ignores tasks whose process server type is not exported" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "something_else", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        assert_equal [], get_json("/deployments/registered")["registered_deployments"]
                    end

                    it "reports if a deployment has not been created by the REST API" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "localhost", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:created_here?).with(configured_deployment)
                                                       .once.and_return(false)
                        result = get_json "/deployments/registered"
                        refute result["registered_deployments"][0]["created"]
                    end

                    it "reports if a deployment has been created by the REST API" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "localhost", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:created_here?).with(configured_deployment)
                                                       .once.and_return(true)
                        result = get_json "/deployments/registered"
                        assert result["registered_deployments"][0]["created"]
                    end

                    it "reports overriden deployments but not the tasks they are replaced by" do
                        configured_deployment = Models::ConfiguredDeployment.new(
                            "unmanaged_tasks", @deployment_m, Hash[], "test_deployment", {}
                        )
                        overriden = Models::ConfiguredDeployment.new(
                            "localhost", @deployment_m, Hash[], "test_deployment", {}
                        )
                        @configured_deployments << configured_deployment
                        mock = flexmock(RESTDeploymentManager).new_instances
                        mock.should_receive(:each_overriden_deployment)
                            .and_return([overriden])
                        mock.should_receive(:used_in_override?)
                            .with(configured_deployment)
                            .and_return(true)
                        mock.should_receive(:used_in_override?)
                            .with(overriden)
                            .and_return(false)
                        result = get_json "/deployments/registered"

                        expected = Hash[
                            "id" => overriden.object_id,
                            "deployment_name" => "test_deployment",
                            "on" => "localhost",
                            "mappings" => Hash["test_task" => "test_task"],
                            "tasks" => [
                                Hash["task_name" => "test_task",
                                     "task_model_name" => "test::Task"]
                            ],
                            "type" => "orocos",
                            "created" => false
                        ]
                        assert_equal [expected], result["registered_deployments"]
                    end
                end

                describe "POST /deployments" do
                    it "registers a plain deployment if 'as' is not given and returns the ID" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:use_deployment).with("test_deployment")
                                                       .once.and_return(123)
                        result = post_json "/deployments?name=test_deployment"
                        assert_equal Hash["registered_deployment" => 123], result
                    end

                    it "registers a mapped deployment if 'as' is given and returns the ID" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:use_deployment).with("test_deployment" => "prefix")
                                                       .once.and_return(123)
                        result = post_json "/deployments?name=test_deployment&as=prefix"
                        assert_equal Hash["registered_deployment" => 123], result
                    end

                    it "returns 403 if a task model is given without an explicit 'as'" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:use_deployment).with("test_deployment")
                                                       .once.and_raise(Syskit::TaskNameRequired)
                        result = post "/deployments?name=test_deployment"
                        assert_equal 403, result.status
                        assert_equal "TaskNameRequired", result.headers["x-roby-error"]
                    end

                    it "returns 404 if the required deployment does not exist" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:use_deployment).and_raise(OroGen::NotFound)
                        result = post "/deployments?name=does_not_exist"
                        assert_equal 404, result.status
                        assert_equal "NotFound", result.headers["x-roby-error"]
                    end

                    it "returns 409 if attempting to register a task that is already in use" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:use_deployment).and_raise(TaskNameAlreadyInUse.new("bla", nil, nil))
                        result = post "/deployments?name=test_deployment"
                        assert_equal 409, result.status
                        assert_equal "TaskNameAlreadyInUse", result.headers["x-roby-error"]
                    end
                end

                describe "DELETE /deployments/:id" do
                    it "deregisters the deployment from its ID" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_deployment).with(123)
                                                       .once
                        result = delete "/deployments/123"
                        assert_equal 204, result.status
                    end
                    it "returns 404 if the ID does not exist" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_deployment)
                                                       .and_raise(RESTDeploymentManager::NotFound)
                        result = delete "/deployments/123"
                        assert_equal 404, result.status
                        assert_equal "NotFound", result.headers["x-roby-error"]
                    end
                    it "returns 403 if the ID matches a deployment that was not created by a corresponding register call" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_deployment)
                                                       .and_raise(RESTDeploymentManager::NotCreatedHere)
                        result = delete "/deployments/123"
                        assert_equal 403, result.status
                        assert_equal "NotCreatedHere", result.headers["x-roby-error"]
                    end
                end

                describe "DELETE /deployments" do
                    it "clears the manager" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:clear).once
                        result = delete "/deployments"
                        assert_equal 204, result.status
                    end
                end

                describe "PATCH /deployments/:id/unmanage" do
                    it "overrides the deployment, turning it into an unmanaged task, and returns the unmanaged deployment IDs" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:make_unmanaged).with(123)
                                                       .once.and_return([42, 84])
                        result = patch "/deployments/123/unmanage"
                        assert_equal 200, result.status
                        assert_equal Hash["overriding_deployments" => [42, 84]],
                                     JSON.parse(result.body)
                    end
                    it "returns 404 if the ID does not exist" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:make_unmanaged)
                                                       .and_raise(RESTDeploymentManager::NotFound)
                        result = patch "/deployments/123/unmanage"
                        assert_equal 404, result.status
                        assert_equal "NotFound", result.headers["x-roby-error"]
                    end
                    it "returns 403 if the ID matches a deployment that was not created by a corresponding register call" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:make_unmanaged)
                                                       .and_raise(RESTDeploymentManager::UsedInOverride)
                        result = patch "/deployments/123/unmanage"
                        assert_equal 403, result.status
                        assert_equal "UsedInOverride", result.headers["x-roby-error"]
                    end
                end

                describe "PATCH /deployments/:id/manage" do
                    it "removes an existing override" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_override).with(123)
                                                       .once
                        result = patch "/deployments/123/manage"
                        assert_equal 200, result.status
                    end
                    it "returns 404 if the deployment does not exist" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_override)
                                                       .and_raise(RESTDeploymentManager::NotFound)
                        result = patch "/deployments/123/manage"
                        assert_equal 404, result.status
                        assert_equal "NotFound", result.headers["x-roby-error"]
                    end
                    it "returns 403 if the deployment is not suitable" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:deregister_override)
                                                       .and_raise(RESTDeploymentManager::NotOverriden)
                        result = patch "/deployments/123/manage"
                        assert_equal 403, result.status
                        assert_equal "NotOverriden", result.headers["x-roby-error"]
                    end
                end

                describe "GET /deployments/:id/command_line" do
                    before do
                        flexmock(@roby_app).should_receive(:log_dir).and_return("/some/log/dir")
                    end
                    it "returns the command line as a hash" do
                        command_line = Orocos::Process::CommandLine.new(
                            Hash["ENV" => "VAR"],
                            "/path/to/command",
                            ["--some", "args"],
                            "/some/log/dir"
                        )
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:command_line).with(123, Hash)
                                                       .and_return(command_line)
                        result = get_json "/deployments/123/command_line"
                        expected = Hash[
                            "env" => command_line.env,
                            "command" => command_line.command,
                            "args" => command_line.args,
                            "working_directory" => "/some/log/dir"
                        ]
                        assert_equal expected, result
                    end

                    it "passes sane default configuration" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:command_line)
                                                       .with(123, tracing: false, name_service_ip: "localhost")
                                                       .and_return(Orocos::Process::CommandLine.new)
                        get_json "/deployments/123/command_line"
                    end

                    it "allows to override the defaults" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:command_line)
                                                       .with(123, tracing: true, name_service_ip: "some_ip")
                                                       .and_return(Orocos::Process::CommandLine.new)
                        get_json "/deployments/123/command_line?tracing=true&name_service_ip=some_ip"
                    end

                    it "returns 404 if the deployment does not exist" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:command_line)
                                                       .and_raise(RESTDeploymentManager::NotFound)
                        result = get "/deployments/123/command_line"
                        assert_equal 404, result.status
                        assert_equal "NotFound", result.headers["x-roby-error"]
                    end

                    it "returns 403 if the deployment is not suitable for command line generation" do
                        flexmock(RESTDeploymentManager).new_instances
                                                       .should_receive(:command_line)
                                                       .and_raise(RESTDeploymentManager::NotOrogen)
                        result = get "/deployments/123/command_line"
                        assert_equal 403, result.status
                        assert_equal "NotOrogen", result.headers["x-roby-error"]
                    end
                end
            end
        end
    end
end
