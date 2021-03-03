# frozen_string_literal: true

require "syskit/test/self"
require "syskit/roby_app/rest_deployment_manager"
module Syskit
    module RobyApp
        describe RESTDeploymentManager do
            before do
                @roby_app = Roby::Application.new
                @conf = Configuration.new(@roby_app)
                @localhost = flexmock(:on, Syskit::RobyApp::RemoteProcesses::Client)
                @conf.register_process_server("localhost", @localhost)
                @unmanaged_tasks = flexmock
                @conf.register_process_server("unmanaged_tasks", @unmanaged_tasks)

                @orogen_task_m = OroGen::Spec::TaskContext.new(
                    @roby_app.default_orogen_project, "test::Task"
                )
                @task_m = Syskit::TaskContext.new_submodel(orogen_model: @orogen_task_m)
                @orogen_deployment_m = OroGen::Spec::Deployment.new(
                    @roby_app.default_orogen_project, "test_deployment"
                )
                @orogen_deployment_m.task "test_task", @orogen_task_m
                @deployment_m = Syskit::Deployment.define_from_orogen(@orogen_deployment_m)

                @manager = RESTDeploymentManager.new(@conf)
            end

            def stub_configured_deployment(on: "localhost", model: @deployment_m, process_name: "test_deployment")
                Models::ConfiguredDeployment.new(on, model, {}, process_name, {})
            end

            def stub_registered_deployment(on: "localhost", model: @deployment_m, process_name: "test_deployment")
                configured_deployment = stub_configured_deployment(on: on, model: model, process_name: process_name)
                @conf.deployment_group.register_configured_deployment(configured_deployment)
                configured_deployment
            end

            describe "#make_unmanaged" do
                it "raises NotFound if the deployment does not exist" do
                    assert_raises(RESTDeploymentManager::NotFound) { @manager.make_unmanaged(10) }
                end
                it "overrides an orocos deployment's tasks by unmanaged tasks" do
                    original = stub_registered_deployment.object_id
                    overrides = @manager.make_unmanaged(original)
                    assert_equal 1, overrides.size
                    new_deployment = @manager.find_registered_deployment_by_id(overrides.first)
                    assert_equal "unmanaged_tasks", new_deployment.process_server_name
                    tasks = new_deployment.each_orogen_deployed_task_context_model.to_a
                    assert_equal 1, tasks.size
                    assert_equal "test_task", tasks[0].name
                    assert_equal @orogen_task_m, tasks[0].task_model
                end
                it "raises AlreadyOverriden if the deployment is already overriden" do
                    original = stub_registered_deployment.object_id
                    @manager.make_unmanaged(original)
                    e = assert_raises(RESTDeploymentManager::AlreadyOverriden) do
                        @manager.make_unmanaged(original)
                    end
                    assert_equal "#{original} is already overriden, cannot override it again",
                                 e.message
                end
                it "raises UsedInOverride if the deployment is already used in an override" do
                    original = stub_registered_deployment.object_id
                    overrides = @manager.make_unmanaged(original)
                    e = assert_raises(RESTDeploymentManager::UsedInOverride) do
                        @manager.make_unmanaged(overrides[0])
                    end
                    assert_equal "#{overrides[0]} is already used in an override, cannot override it",
                                 e.message
                end
                it "deregisters the override if an exception is raised" do
                    @orogen_deployment_m.task "another_test_task", @orogen_task_m
                    error = Class.new(RuntimeError)
                    flexmock(@conf.deployment_group)
                        .should_receive(:use_unmanaged_task).once.pass_thru
                    flexmock(@conf.deployment_group)
                        .should_receive(:use_unmanaged_task).once.and_raise(error)

                    original = stub_registered_deployment.object_id
                    assert_raises(error) do
                        @manager.make_unmanaged(original)
                    end
                    assert_equal [original], @conf.deployment_group
                                                  .each_configured_deployment.map(&:object_id)
                end
            end

            describe "#each_overriden_deployment" do
                it "reports the deployments that have been overriden" do
                    original = stub_registered_deployment
                    @manager.make_unmanaged(original.object_id)
                    assert_equal [original], @manager.each_overriden_deployment.to_a
                end
                it "does not report a deployment once its override is removed" do
                    original = stub_registered_deployment
                    @manager.make_unmanaged(original.object_id)
                    @manager.deregister_override(original.object_id)
                    assert_equal [], @manager.each_overriden_deployment.to_a
                end
                it "does not report new definitions" do
                    @manager.use_deployment(@deployment_m => "test")
                    assert_equal [], @manager.each_overriden_deployment.to_a
                end
            end

            describe "#created_here?" do
                it "returns false for an in-app deployment" do
                    refute @manager.created_here?(stub_registered_deployment)
                end

                it "returns true for a newly defined deployment" do
                    id = @manager.use_deployment(@deployment_m => "prefix")
                    d  = @manager.find_new_deployment_by_id(id)
                    assert @manager.created_here?(d)
                end

                it "returns false once a newly defined deployment is removed" do
                    id = @manager.use_deployment(@deployment_m => "prefix")
                    d  = @manager.find_new_deployment_by_id(id)
                    @manager.deregister_deployment(id)
                    refute @manager.created_here?(d)
                end

                it "returns false for an overriden deployment" do
                    original = stub_registered_deployment.object_id
                    @manager.make_unmanaged(original)
                    refute @manager.created_here?(original)
                end

                it "returns true for a deployment created to handle an override" do
                    original = stub_registered_deployment.object_id
                    ids = @manager.make_unmanaged(original)
                    d   = @manager.find_registered_deployment_by_id(ids.first)
                    assert @manager.created_here?(d)
                end

                it "returns false once a deployment created to handle an override is removed" do
                    original = stub_registered_deployment.object_id
                    ids = @manager.make_unmanaged(original)
                    d   = @manager.find_registered_deployment_by_id(ids.first)
                    @manager.deregister_override(original)
                    refute @manager.created_here?(d)
                end
            end

            describe "#deregister_deployment" do
                it "raises NotCreatedHere if trying to deregister a deployment that comes from the app" do
                    original = stub_registered_deployment
                    assert_raises(RESTDeploymentManager::NotCreatedHere) do
                        @manager.deregister_deployment(original.object_id)
                    end
                end
                it "raises UsedInOverride if trying to deregister a deployment that has been created for an overidde" do
                    original = stub_registered_deployment
                    overrides = @manager.make_unmanaged(original.object_id)
                    assert_raises(RESTDeploymentManager::UsedInOverride) do
                        @manager.deregister_deployment(overrides.first)
                    end
                end
                it "raises NotFound if there is no deployment for the given ID" do
                    assert_raises(RESTDeploymentManager::NotFound) do
                        @manager.deregister_deployment(10)
                    end
                end
                it "removes the deployment from the manager" do
                    id = @manager.use_deployment(@deployment_m => "test")
                    @manager.deregister_deployment(id)
                    assert_nil @manager.find_new_deployment_by_id(id)
                end
                it "removes the deployment from the configuration" do
                    id = @manager.use_deployment(@deployment_m => "test")
                    @manager.deregister_deployment(id)
                    assert_nil @manager.find_registered_deployment_by_id(id)
                end
            end

            describe "#deregister_override" do
                it "raises NotOverriden if trying to deregister a deployment that comes from the app" do
                    original = stub_registered_deployment
                    assert_raises(RESTDeploymentManager::NotOverriden) do
                        @manager.deregister_override(original.object_id)
                    end
                end
                it "raises NotOverriden if trying to deregister a deployment that has been created for an overidde" do
                    original = stub_registered_deployment
                    overrides = @manager.make_unmanaged(original.object_id)
                    assert_raises(RESTDeploymentManager::NotOverriden) do
                        @manager.deregister_override(overrides.first)
                    end
                end
                it "raises NotFound if there is no deployment for the given ID" do
                    assert_raises(RESTDeploymentManager::NotFound) do
                        @manager.deregister_override(10)
                    end
                end
                it "removes the override from the manager" do
                    original = stub_registered_deployment
                    @manager.make_unmanaged(original.object_id)
                    @manager.deregister_override(original.object_id)
                    refute @manager.overriden?(original.object_id)
                end
                it "removes the deployment from the configuration" do
                    id = @manager.use_deployment(@deployment_m => "test")
                    @manager.deregister_deployment(id)
                    assert_nil @manager.find_registered_deployment_by_id(id)
                end
            end

            describe "#clear" do
                it "deregisters new deployments" do
                    @manager.use_deployment(@deployment_m => "test")
                    @manager.clear
                    assert_equal [], @conf.deployment_group.each_configured_deployment
                                          .map(&:object_id)
                end
                it "deregisters overrides" do
                    original = stub_registered_deployment
                    @manager.make_unmanaged(original.object_id)
                    @manager.clear
                    assert_equal [original.object_id], @conf.deployment_group.each_configured_deployment
                                                            .map(&:object_id)
                end
            end

            describe "#command_line" do
                before do
                    flexmock(@roby_app).should_receive(:log_dir).and_return("/some/log/dir")
                end

                it "returns a command line valid for the given deployment" do
                    deployment = stub_registered_deployment
                    flexmock(@roby_app.default_pkgconfig_loader)
                        .should_receive(:find_deployment_binfile)
                        .with(deployment.model.orogen_model.name)
                        .and_return("/path/to/deployment")
                    command_line = @manager.command_line(deployment.object_id)
                    assert_equal "/path/to/deployment", command_line.command
                end

                it "raises NotFound if the deployment does not exist" do
                    assert_raises(RESTDeploymentManager::NotFound) do
                        @manager.command_line(42)
                    end
                end

                it "returns a command line valid for an overriden deployment" do
                    deployment = stub_registered_deployment
                    flexmock(@roby_app.default_pkgconfig_loader)
                        .should_receive(:find_deployment_binfile)
                        .with(deployment.model.orogen_model.name)
                        .and_return("/path/to/deployment")
                    @manager.make_unmanaged(deployment.object_id)
                    command_line = @manager.command_line(deployment.object_id)
                    assert_equal "/path/to/deployment", command_line.command
                end

                it "raises NotOrogen if the deployment is not an orogen deployment" do
                    deployment = stub_registered_deployment(on: "unmanaged_tasks")
                    assert_raises(RESTDeploymentManager::NotOrogen) do
                        @manager.command_line(deployment.object_id)
                    end
                end
            end
        end
    end
end
