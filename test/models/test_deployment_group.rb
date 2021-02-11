# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe DeploymentGroup do
            attr_reader :conf, :loader, :group
            before do
                app = Roby::Application.new
                @conf = RobyApp::Configuration.new(app)
                @loader = OroGen::Loaders::Base.new
                @group = DeploymentGroup.new
                conf.register_process_server(
                    "ruby_tasks", Orocos::RubyTasks::ProcessManager.new(loader), ""
                )
                conf.register_process_server(
                    "test-mng", Orocos::RubyTasks::ProcessManager.new(loader), ""
                )
            end

            describe "#empty?" do
                it "returns true if the group has no deployments" do
                    assert group.empty?
                end
                it "returns false if the group has a deployment" do
                    deployment_m = Syskit::Deployment.new_submodel
                    group.register_configured_deployment(
                        ConfiguredDeployment.new("test", deployment_m,
                                                 Hash["task" => "task"])
                    )
                    refute group.empty?
                end
            end

            describe "#use_group" do
                attr_reader :task_m, :deployment_m,
                            :self_deployment, :other_group, :other_deployment

                before do
                    @task_m = task_m = Syskit::TaskContext.new_submodel
                    @deployment_m = Syskit::Deployment.new_submodel do
                        task "task", task_m.orogen_model
                    end
                    @other_group = DeploymentGroup.new
                    @other_deployment = other_group.use_deployment(
                        Hash[deployment_m => "other_"],
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    @self_deployment = group.use_deployment(
                        Hash[deployment_m => "self_"],
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                end

                it "merges the argument's registered deployments with the local" do
                    group.use_group(other_group)

                    assert_equal other_deployment, group
                        .find_deployment_from_task_name("other_task")
                    assert_equal self_deployment, group
                        .find_deployment_from_task_name("self_task")
                    assert_equal Set[other_deployment, self_deployment],
                                 group.find_all_deployments_from_process_manager("test-mng")
                end

                it "does not modify its argument" do
                    group.use_group(other_group)

                    assert_equal other_deployment, other_group
                        .find_deployment_from_task_name("other_task")
                    refute other_group
                        .find_deployment_from_task_name("self_task")
                    assert_equal Set[other_deployment],
                                 other_group.find_all_deployments_from_process_manager("test-mng")
                end

                it "passes if the two groups have the same deployment" do
                    other_group.use_deployment(Hash[deployment_m => "self_"],
                                               on: "test-mng", process_managers: conf,
                                               loader: loader).first
                    group.use_group(other_group)

                    assert_equal other_deployment, group
                        .find_deployment_from_task_name("other_task")
                    assert_equal self_deployment, group
                        .find_deployment_from_task_name("self_task")
                    assert_equal Set[other_deployment, self_deployment],
                                 group.find_all_deployments_from_process_manager("test-mng")
                end

                it "raises if the receiver and argument have clashing task names "\
                    "and leaves the receiver as-is" do
                    clash = other_group.use_deployment(Hash[deployment_m => "self_"],
                                                       on: "test-mng", process_managers: conf, loader: loader).first
                    flexmock(self_deployment).should_receive(:==)
                                             .with(clash).and_return(false)
                    assert_raises(TaskNameAlreadyInUse) do
                        group.use_group(other_group)
                    end
                    refute group.find_deployment_from_task_name("other_task")
                    # Can't use assert_equal here as we override #==
                    assert_same self_deployment, group
                        .find_deployment_from_task_name("self_task")
                    assert_equal Set[self_deployment],
                                 group.find_all_deployments_from_process_manager("test-mng")
                end

                it "keeps the two groups separate" do
                    group = DeploymentGroup.new
                    group.use_group(other_group)
                    other_group.use_deployment(Hash[deployment_m => "self_"],
                                               on: "test-mng", process_managers: conf,
                                               loader: loader).first
                    assert_equal Set[other_deployment], group
                        .find_all_deployments_from_process_manager("test-mng")
                    refute group.find_deployment_from_task_name("self_task")
                end
            end

            describe "#task_context_deployment_candidates" do
                attr_reader :task_m, :deployment_m
                before do
                    @task_m = task_m = Syskit::TaskContext.new_submodel
                    @deployment_m = Syskit::Deployment.new_submodel do
                        task "task", task_m.orogen_model
                    end
                end

                it "registers the mapping from task models to available deployments" do
                    first = group.use_deployment(
                        { deployment_m => "1_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    second = group.use_deployment(
                        { deployment_m => "2_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first

                    deployed_tasks =
                        Set[DeploymentGroup::DeployedTask.new(first, "1_task"),
                            DeploymentGroup::DeployedTask.new(second, "2_task")]

                    assert_equal(
                        { task_m => deployed_tasks },
                        group.task_context_deployment_candidates
                    )
                end

                it "caches the computed result" do
                    group.task_context_deployment_candidates
                    flexmock(group)
                        .should_receive(:compute_task_context_deployment_candidates)
                        .never
                    group.task_context_deployment_candidates
                end

                it "recomputes on #invalidate_cache" do
                    group.task_context_deployment_candidates
                    flexmock(group)
                        .should_receive(:compute_task_context_deployment_candidates)
                        .once
                    group.invalidate_caches
                    group.task_context_deployment_candidates
                end
            end

            describe "#find_all_suitable_deployments_for" do
                attr_reader :task_m, :deployment_m
                before do
                    @task_m = task_m = Syskit::TaskContext.new_submodel
                    @deployment_m = Syskit::Deployment.new_submodel do
                        task "task", task_m.orogen_model
                    end
                end

                it "returns matching deployments with the exact task model" do
                    first = group.use_deployment(
                        { deployment_m => "1_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    second = group.use_deployment(
                        { deployment_m => "2_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    task = task_m.new
                    assert_equal(
                        Set[DeploymentGroup::DeployedTask.new(first, "1_task"),
                            DeploymentGroup::DeployedTask.new(second, "2_task")],
                        group.find_all_suitable_deployments_for(task)
                    )
                end

                it "returns deployments valid for the task's concrete model if there are none for the actual" do
                    first = group.use_deployment(
                        { deployment_m => "1_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    second = group.use_deployment(
                        { deployment_m => "2_" },
                        on: "test-mng", process_managers: conf, loader: loader
                    ).first
                    task = task_m.new
                    task.specialize
                    refute_same task.concrete_model, task.model
                    assert_equal(
                        Set[DeploymentGroup::DeployedTask.new(first, "1_task"),
                            DeploymentGroup::DeployedTask.new(second, "2_task")],
                        group.find_all_suitable_deployments_for(task)
                    )
                end

                it "returns an empty set if there is no match" do
                    assert_equal(
                        Set[], group.find_all_suitable_deployments_for(task_m.new)
                    )
                end
            end

            describe "#register_configured_deployment" do
                attr_reader :task_m, :deployment_m

                before do
                    @task_m = task_m = Syskit::TaskContext.new_submodel
                    @deployment_m = Syskit::Deployment.new_submodel do
                        task "task", task_m.orogen_model
                    end
                end

                it "raises TaskNameAlreadyInUse if a task of this deployment's "\
                    "uses an existing name from another deployment" do
                    group.register_configured_deployment(
                        ConfiguredDeployment.new("test", deployment_m,
                                                 Hash["task" => "task"])
                    )
                    assert_raises(TaskNameAlreadyInUse) do
                        group.register_configured_deployment(
                            ConfiguredDeployment.new("other", deployment_m,
                                                     Hash["task" => "task"])
                        )
                    end
                end
                it "passes if trying to re-register the same deployment" do
                    configured_deployment = ConfiguredDeployment.new(
                        "test", deployment_m, Hash["task" => "task"]
                    )
                    group.register_configured_deployment(configured_deployment)
                    group.register_configured_deployment(configured_deployment)
                end

                it "registers the deployment based on the mapped deployed task models" do
                    configured_deployment = ConfiguredDeployment.new(
                        "test", deployment_m, Hash["task" => "test"]
                    )
                    group.register_configured_deployment(configured_deployment)
                    assert_same configured_deployment, group
                        .find_deployment_from_task_name("test")
                    assert !group.find_deployment_from_task_name("task")
                end

                it "registers the deployment on its process manager" do
                    configured_deployment = ConfiguredDeployment.new(
                        "process_mng", deployment_m, Hash["task" => "test"]
                    )
                    group.register_configured_deployment(configured_deployment)
                    assert_equal [configured_deployment], group
                        .find_all_deployments_from_process_manager("process_mng").to_a
                end

                it "invalidates the cache" do
                    flexmock(group).should_receive(:invalidate_caches).once
                    configured_deployment = ConfiguredDeployment.new(
                        "process_mng", deployment_m, Hash["task" => "test"]
                    )
                    group.register_configured_deployment(configured_deployment)
                end
            end

            describe "#use_ruby_tasks" do
                attr_reader :deployment_m, :task_m
                before do
                    @deployment_m = Syskit::Deployment.new_submodel
                    @task_m = Syskit::RubyTaskContext.new_submodel
                    flexmock(task_m).should_receive(:deployment_model)
                                    .and_return(deployment_m)
                end

                it "registers a configured deployment using #deployment_model" do
                    expected = ConfiguredDeployment.new(
                        "test-mng", deployment_m, Hash["task" => "test"],
                        "test", Hash[task_context_class: Orocos::RubyTasks::TaskContext]
                    )
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .once
                    configured_deployment = group.use_ruby_tasks(
                        Hash[task_m => "test"], on: "test-mng", process_managers: conf
                    )
                    assert_equal [expected], configured_deployment
                end
                it "raises if the process manager does not exist" do
                    assert_raises(RobyApp::Configuration::UnknownProcessServer) do
                        group.use_ruby_tasks(Hash[task_m => "test"], on: "does_not_exist")
                    end
                end
                it "gives a proper error if the mappings argument is not a hash" do
                    e = assert_raises(ArgumentError) do
                        @group.use_ruby_tasks @task_m,
                                              process_managers: @conf
                    end
                    assert_equal "mappings should be given as model => name", e.message
                end

                it "warns about deprecation of multiple definitions" do
                    task1_m = Syskit::RubyTaskContext.new_submodel
                    flexmock(Roby).should_receive(:warn_deprecated)
                                  .with(/defining more than one ruby/).once
                    @group.use_ruby_tasks(Hash[@task_m => "a", task1_m => "b"],
                                          process_managers: @conf)
                end

                it "raises if the model is a composition" do
                    cmp_m = Syskit::Composition.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_ruby_tasks(Hash[cmp_m => "task"],
                                              process_managers: @conf)
                    end
                    assert_equal "#{cmp_m} is not a ruby task model", e.message
                end

                it "raises if the model is a plain TaskContext" do
                    task_m = Syskit::TaskContext.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_ruby_tasks(Hash[task_m => "task"],
                                              process_managers: @conf)
                    end
                    assert_equal "#{task_m} is not a ruby task model", e.message
                end
            end

            describe "#use_unmanaged_task" do
                attr_reader :task_m
                before do
                    conf.register_process_server("unmanaged_tasks",
                                                 RobyApp::UnmanagedTasksManager.new, "")
                    @task_m = Syskit::TaskContext.new_submodel(
                        name: "Test", orogen_model_name: "test::Task"
                    )
                end

                it "creates a deployment model and registers it" do
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng", configured_deployment
                            .process_server_name
                        assert_equal "test", configured_deployment.process_name
                        assert_equal Hash["test" => "test"], configured_deployment
                            .name_mappings
                        task_name, task_model = configured_deployment
                                                .each_deployed_task_model.first
                        assert_equal "test", task_name
                        assert_equal task_m, task_model
                        true
                    end

                    flexmock(group).should_receive(:register_configured_deployment)
                                   .with(expected).once
                    configured_deployment = group.use_unmanaged_task(
                        Hash[task_m => "test"],
                        on: "test-mng", process_managers: conf
                    )
                                                 .first
                    expected[configured_deployment]

                    assert_equal "test-mng", configured_deployment.process_server_name
                end

                it "resolves a task model given as string" do
                    flexmock(Syskit::TaskContext)
                        .should_receive(:find_model_from_orogen_name).with("test::Task")
                        .and_return(task_m).once
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng", configured_deployment
                            .process_server_name
                        assert_equal "test", configured_deployment
                            .process_name
                        assert_equal Hash["test" => "test"], configured_deployment
                            .name_mappings
                        task_name, task_model = configured_deployment
                                                .each_deployed_task_model.first
                        assert_equal "test", task_name
                        assert_equal task_m, task_model
                        true
                    end
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .with(expected).once

                    deprecated_feature do
                        group.use_unmanaged_task(Hash["test::Task" => "test"],
                                                 on: "test-mng", process_managers: conf)
                    end
                end

                it "raises if the process manager does not exist" do
                    assert_raises(RobyApp::Configuration::UnknownProcessServer) do
                        group.use_unmanaged_task(Hash[task_m => "test"],
                                                 on: "does_not_exist")
                    end
                end

                it "raises if the model is a Composition" do
                    cmp_m = Syskit::Composition.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_unmanaged_task(Hash[cmp_m => "name"],
                                                  process_managers: @conf)
                    end
                    assert_equal "expected a mapping from a task context model to "\
                        "a name, but got #{cmp_m}", e.message
                end
                it "raises if the model is a RubyTaskContext" do
                    task_m = Syskit::RubyTaskContext.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_unmanaged_task(Hash[task_m => "name"],
                                                  process_managers: @conf)
                    end
                    assert_equal "expected a mapping from a task context model to "\
                        "a name, but got #{task_m}", e.message
                end
            end

            describe "#use_deployment" do
                attr_reader :task_m, :deployment_m
                before do
                    @task_m = Syskit::TaskContext.new_submodel(
                        orogen_model_name: "test::Task"
                    )
                    @deployment_m = Syskit::Deployment.new_submodel(
                        name: "test_deployment"
                    )
                    flexmock(loader).should_receive(:deployment_model_from_name)
                                    .with("test_deployment")
                                    .and_return(deployment_m.orogen_model)
                    flexmock(loader).should_receive(:deployment_model_from_name)
                                    .with(OroGen::Spec::Project.default_deployment_name("test::Task"))
                                    .and_return(deployment_m.orogen_model)
                    conf.register_process_server(
                        "localhost", Orocos::RubyTasks::ProcessManager.new(
                                         Roby.app.default_loader
                                     ), ""
                    )
                    conf.register_process_server(
                        "test", Orocos::RubyTasks::ProcessManager.new(
                                    Roby.app.default_loader
                                ), ""
                    )
                end
                it "resolves the TaskModelClass => name syntax" do
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng", configured_deployment.process_server_name
                        assert_equal deployment_m, configured_deployment.model
                        assert_equal "test", configured_deployment.process_name
                        expected_name_mapping = Hash[
                            "orogen_default_test__Task" => "test",
                            "orogen_default_test__Task_Logger" => "test_Logger"]
                        assert_equal expected_name_mapping,
                                     configured_deployment.name_mappings
                        true
                    end
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .once.with(expected)

                    actual = group.use_deployment(Hash[task_m => "test"], on: "test-mng",
                                                                          process_managers: conf, loader: loader).first
                    assert expected[actual]
                end

                it "resolves a deployment by object" do
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng", configured_deployment.process_server_name
                        assert_equal deployment_m, configured_deployment.model
                        assert_equal "test_deployment", configured_deployment.process_name
                        expected_name_mapping = Hash[]
                        assert_equal expected_name_mapping,
                                     configured_deployment.name_mappings
                        true
                    end
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .once.with(expected)
                    actual = group.use_deployment(deployment_m,
                                                  on: "test-mng", process_managers: conf, loader: loader).first
                    assert expected[actual]
                end

                it "resolves a deployment by name" do
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng", configured_deployment.process_server_name
                        assert_equal deployment_m, configured_deployment.model
                        assert_equal "test_deployment", configured_deployment.process_name
                        expected_name_mapping = Hash[]
                        assert_equal expected_name_mapping,
                                     configured_deployment.name_mappings
                        true
                    end
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .once.with(expected)
                    flexmock(loader).should_receive(:task_model_from_name)
                                    .and_raise(OroGen::NotFound)
                    actual = group.use_deployment("test_deployment",
                                                  on: "test-mng", process_managers: conf, loader: loader).first
                    assert expected[actual]
                end

                it "overrides the process server with the stub process server "\
                    "if simulation? is true" do
                    expected = lambda do |configured_deployment|
                        assert_equal "test-mng-sim", configured_deployment
                            .process_server_name
                        true
                    end
                    flexmock(group).should_receive(:register_configured_deployment)
                                   .once.with(expected)

                    actual = group.use_deployment(Hash[task_m => "test"],
                                                  on: "test-mng", process_managers: conf,
                                                  loader: loader, simulation: true).first
                    assert expected[actual]
                end

                it "sets an identity name mapping for deployments that "\
                    "are not prefixed" do
                    deployment_m.orogen_model.task "task", task_m.orogen_model
                    configured_deployment = group.use_deployment(deployment_m,
                                                                 on: "test-mng", process_managers: conf, loader: loader).first
                    assert_equal Hash["task" => "task"],
                                 configured_deployment.name_mappings
                end

                it "raises if the given model is a composition" do
                    cmp_m = Syskit::Composition.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_deployment cmp_m => "task"
                    end
                    assert_equal "only deployment and task context models can be "\
                        "deployed by use_deployment, got #{cmp_m}", e.message
                end

                it "raises if the given model is a RubyTaskContext" do
                    task_m = Syskit::RubyTaskContext.new_submodel
                    e = assert_raises(ArgumentError) do
                        @group.use_deployment task_m => "task"
                    end
                    assert_equal "only deployment and task context models can be "\
                        "deployed by use_deployment, got #{task_m}", e.message
                end

                it "raises if the task has no default deployment" do
                    assert_raises(OroGen::DeploymentModelNotFound) do
                        @group.use_deployment task_m => "task"
                    end
                end

                it "does not raise if the same deployment is configured "\
                   "with a different mapping" do
                    deployment1_m = stub_deployment "deployment1"
                    @group.use_deployment deployment1_m
                    @group.use_deployment deployment1_m => "prefix_"
                end
                it "does not raise if the same deployment is registered again" do
                    deployment1_m = stub_deployment "deployment1"
                    @group.use_deployment deployment1_m
                    @group.use_deployment deployment1_m
                end
                it "registers the same deployment only once" do
                    deployment1_m = stub_deployment "deployment1"
                    @group.use_deployment deployment1_m
                    @group.use_deployment deployment1_m
                    assert_equal 1, @group
                        .find_all_deployments_from_process_manager("localhost").size
                end
                it "should allow registering on another process server" do
                    deployment1_m = stub_deployment "deployment1"
                    @group.use_deployment deployment1_m,
                                          on: "test", process_managers: @conf
                    assert_equal 1, @group
                        .find_all_deployments_from_process_manager("test").size
                end
                it "raises OroGen::NotFound if the deployment does not exist" do
                    e = assert_raises(OroGen::NotFound) do
                        @group.use_deployment "does_not_exist",
                                              on: "test", process_managers: @conf
                    end
                    assert_equal "does_not_exist is neither a task model "\
                        "nor a deployment name", e.message
                end
                it "raises TaskNameRequired if passing a task model "\
                    "without giving an explicit name" do
                    e = assert_raises(Syskit::TaskNameRequired) do
                        @group.use_deployment(@task_m,
                                              on: "test", process_managers: @conf)
                    end
                    assert_equal "you must provide a task name when starting "\
                        "a component by type, as e.g. use_deployment "\
                        "OroGen.xsens_imu.Task => 'imu'",
                                 e.message
                end
            end

            describe "#use_deployments_from" do
                attr_reader :task_m, :deployment_m
                before do
                    @task_m = Syskit::TaskContext.new_submodel(
                        orogen_model_name: "test::Task"
                    )
                    @deployment_m = Syskit::Deployment.new_submodel(
                        name: "test_deployment"
                    )
                    flexmock(loader).should_receive(:deployment_model_from_name)
                                    .with("test_deployment")
                                    .and_return(deployment_m.orogen_model)
                    flexmock(loader).should_receive(:deployment_model_from_name)
                                    .with(OroGen::Spec::Project.default_deployment_name("test::Task"))
                                    .and_return(deployment_m.orogen_model)
                end

                it "registers all deployments of the given project" do
                    flexmock(loader).should_receive(:project_model_from_name)
                                    .with("test_project")
                                    .and_return(project = flexmock)
                    project.should_receive(:each_deployment)
                           .and_yield(deployment_m.orogen_model)

                    flexmock(group)
                        .should_receive(:use_deployment)
                        .with("test_deployment",
                              on: "test-mng", process_managers: conf, loader: loader,
                              simulation: nil)
                        .once
                    group.use_deployments_from(
                        "test_project",
                        on: "test-mng", process_managers: conf, loader: loader
                    )
                end

                it "ignores uninstalled deployments" do
                    flexmock(loader).should_receive(:project_model_from_name)
                                    .with("test_project")
                                    .and_return(project = flexmock)
                    project.should_receive(:each_deployment)
                           .and_yield(flexmock(:install? => false))

                    flexmock(group).should_receive(:use_deployment).never
                    group.use_deployments_from("test_project",
                                               on: "test-mng", process_managers: conf, loader: loader)
                end
            end

            def stub_deployment(name)
                task_m = @task_m
                Syskit::Deployment.new_submodel(name: name) do
                    task("task", task_m.orogen_model)
                end
            end
        end
    end
end
