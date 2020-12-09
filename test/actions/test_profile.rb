# frozen_string_literal: true

require "syskit/test/self"

module SyskitProfileTest
end

module Syskit
    module Actions
        describe Profile do
            describe "#initialize" do
                it "does not register the profile as a submodel of the Profile "\
                   "module by default" do
                    new_profile = Profile.new
                    refute Profile.each_submodel.to_a.include?(new_profile)
                end

                it "registers the profile if register: true" do
                    new_profile = Profile.new(register: true)
                    assert Profile.each_submodel.to_a.include?(new_profile)
                end

                it "sets the profile's name" do
                    profile = Profile.new("name")
                    assert_equal "name", profile.name
                end
            end

            describe "global #profile method" do
                before do
                    @context = Module.new
                end

                it "registers the newly created profile as a submodel of Profile" do
                    new_profile = @context.profile("Test") {}
                    assert Profile.each_submodel.to_a.include?(new_profile)
                end

                it "registers the newly created profile as a constant "\
                   "on the context module" do
                    new_profile = @context.profile("Test") {}
                    assert_same @context::Test, new_profile
                end

                it "evaluates the block on an already registered constant with "\
                   "the same name" do
                    test_profile = @context.profile("Test") {}
                    flexmock(Profile).should_receive(:new).never

                    eval_context = nil
                    @context.profile("Test") do
                        eval_context = self
                    end
                    assert_same test_profile, eval_context
                end
            end

            describe "#use_profile" do
                attr_reader :definition_mock
                before do
                    @definition_mock = flexmock(arguments: [], with_arguments: nil)
                    definition_mock.should_receive(:push_selections).by_default
                    definition_mock.should_receive(:composition_model?).by_default
                    definition_mock.should_receive(:use).by_default
                    definition_mock.should_receive(:doc).by_default
                end

                it "resets the profile to the new profile" do
                    task_m = TaskContext.new_submodel
                    src = Profile.new
                    src.define "test", task_m
                    dst = Profile.new
                    dst.use_profile src
                    assert_same src, src.test_def.profile
                    assert_same dst, dst.test_def.profile
                end

                it "imports the existing definitions" do
                    task_m = TaskContext.new_submodel
                    src = Profile.new
                    src.define "test", task_m

                    dst = Profile.new
                    flexmock(dst)
                        .should_receive(:register_definition)
                        .with("test", src.test_def, doc: nil).once
                        .and_return(definition_mock)
                    dst.use_profile src
                end

                it "allows to transform the definition names" do
                    src = Profile.new
                    src.define "test", TaskContext.new_submodel
                    assert_equal "test", src.test_def.name

                    dst = Profile.new
                    dst.use_profile src, transform_names: ->(name) { "modified_#{name}" }

                    assert_equal "modified_test", dst.modified_test_def.name
                    assert_equal src.test_def, dst.modified_test_def
                end

                it "uses the existing definition's documentation as documentation "\
                   "for the imported definition" do
                    task_m = TaskContext.new_submodel
                    src = Profile.new
                    req = src.define "test", task_m
                    req.doc "test documentation"

                    dst = Profile.new
                    flexmock(dst)
                        .should_receive(:register_definition)
                        .with("test", src.test_def, doc: "test documentation").once
                        .and_return(definition_mock)
                    dst.use_profile src
                end

                it "does not import definitions that are already existing "\
                   "on the receiver" do
                    task_m = TaskContext.new_submodel
                    src = Profile.new
                    src.define "test", task_m

                    dst = Profile.new
                    dst.define "test", task_m
                    flexmock(dst).should_receive(:define).never
                    dst.use_profile src
                end

                it "pushes selections before defining on the receiver if "\
                   "the model is a composition" do
                    cmp_m = Composition.new_submodel
                    src = Profile.new
                    src.define "test", cmp_m

                    define = flexmock(src.definitions["test"])
                    define.should_receive(:dup).once
                          .and_return(duped = definition_mock)
                    duped.should_receive(:push_selections).once
                    dst = Profile.new
                    flexmock(dst)
                        .should_receive(:register_definition)
                        .with("test", duped, doc: nil).once
                        .and_return(duped)
                    dst.use_profile src
                end

                it "resolves definitions using the use flags" do
                    srv_m  = DataService.new_submodel
                    task_m = TaskContext.new_submodel { provides srv_m, as: "srv" }
                    profile = Profile.new
                    profile.use srv_m => task_m
                    profile.define "test", srv_m

                    assert_equal task_m.srv_srv, profile.test_def.service
                end

                it "applies selections on the requirement's use flags" do
                    parent_srv_m = DataService.new_submodel(name: "ParentSrv")
                    srv_m = DataService.new_submodel(name: "Srv") do
                        provides parent_srv_m
                    end
                    task_m = TaskContext.new_submodel(name: "Task") do
                        provides srv_m, as: "srv"
                    end
                    cmp_m = Composition.new_submodel(name: "Cmp") do
                        add parent_srv_m, as: "c"
                    end
                    profile = Profile.new
                    profile.use srv_m => task_m
                    profile.define "test", cmp_m.use(srv_m)

                    req = profile.resolved_definition("test")
                    task = req.instanciate(plan)
                    assert_equal task_m, task.c_child.model
                end

                it "allows to apply selections to tags" do
                    srv_m = DataService.new_submodel
                    cmp_m = Composition.new_submodel
                    cmp_m.add srv_m, as: "test"
                    src = Profile.new
                    src.tag "test", srv_m
                    src.define "test", src.test_tag

                    task_m = TaskContext.new_submodel
                    task_m.provides srv_m, as: "test"
                    dst = Profile.new
                    dst.use_profile src, { "test" => task_m }
                end

                it "also promotes definitions that are used as arguments" do
                    srv_m = DataService.new_submodel
                    task_m = TaskContext.new_submodel do
                        argument :requirement
                    end
                    cmp_m = Composition.new_submodel
                    cmp_m.add srv_m, as: "test"
                    parent_profile = Profile.new
                    parent_profile.tag "test", srv_m
                    parent_profile.define "argument_action",
                                          cmp_m.use(parent_profile.test_tag)
                    parent_profile.define "test", task_m.with_arguments(
                        action: parent_profile.argument_action_def.to_action_model
                    )

                    srv_task_m = TaskContext.new_submodel
                    srv_task_m.provides srv_m, as: "test"
                    child_profile = Profile.new
                    child_profile.use_profile parent_profile, { "test" => srv_task_m }
                    task = child_profile.test_def.arguments[:action]
                                        .requirements.instanciate(plan)
                    assert_kind_of srv_task_m, task.test_child
                end
            end

            describe "#define" do
                it "adds a Definition object in which the arguments is merged" do
                    req = InstanceRequirements.new
                    flexmock(Profile::Definition)
                        .new_instances.should_receive(:merge).with(req).once
                    profile = Profile.new
                    result = profile.define "test", req
                    assert_kind_of(Profile::Definition, result)
                end
                it "properly sets the name and profile of the definition object" do
                    req = InstanceRequirements.new
                    profile = Profile.new
                    result = profile.define "test", req
                    assert_equal "test", result.name
                    assert_same profile, result.profile
                end
            end

            describe "#use" do
                it "should allow to globally inject dependencies in all definitions" do
                    srv_m = DataService.new_submodel name: "Srv"
                    task_m = TaskContext.new_submodel name: "Task"
                    task_m.provides srv_m, as: "test"
                    cmp = Composition.new_submodel
                    cmp.add srv_m, as: "test"
                    profile = Profile.new
                    profile.use srv_m => task_m
                    profile.define "test", cmp
                    di = profile.resolved_definition("test").resolved_dependency_injection
                    _, sel = di.selection_for(nil, srv_m)
                    assert_equal task_m, sel.model, "expected #{task_m}, got #{sel.model}"
                end
            end

            describe "#method_missing" do
                attr_reader :profile, :dev_m, :driver_m
                before do
                    @profile = Profile.new
                    @dev_m = Device.new_submodel
                    @driver_m = TaskContext.new_submodel
                    driver_m.driver_for dev_m, as: "driver"
                end
                it "gives access to tags" do
                    srv_m = DataService.new_submodel
                    srv = profile.tag "test", srv_m
                    assert_same srv, profile.test_tag
                end
                it "raises NoMethodError for unknown tags" do
                    assert_raises(NoMethodError) do
                        profile.test_tag
                    end
                end
                it "raises ArgumentError if arguments are given to a _tag method" do
                    profile.tag "test", DataService.new_submodel
                    assert_raises(ArgumentError) do
                        profile.test_tag("bla")
                    end
                end

                it "gives access to definitions" do
                    profile.define "test", DataService.new_submodel
                    flexmock(profile)
                        .should_receive(:find_definition_by_name)
                        .with("test").and_return(d = flexmock)
                    assert_same d, profile.test_def
                end
                it "raises NoMethodError for unknown definitions" do
                    assert_raises(NoMethodError) do
                        profile.test_def
                    end
                end
                it "raises ArgumentError if arguments are given to a _def method" do
                    profile.define "test", DataService.new_submodel
                    assert_raises(ArgumentError) do
                        profile.test_def("bla")
                    end
                end

                it "gives access to devices" do
                    device = profile.robot.device dev_m, as: "test"
                    assert_same driver_m.driver_srv, profile.test_dev.base_model
                    assert_same device, profile.test_dev.arguments[:driver_dev]
                end
                it "raises NoMethodError for unknown devices" do
                    assert_raises(NoMethodError) do
                        profile.test_dev
                    end
                end
                it "raises ArgumentError if arguments are given to a _dev method" do
                    profile.robot.device dev_m, as: "test"
                    assert_raises(ArgumentError) do
                        profile.test_dev("bla")
                    end
                end
            end

            it "should be usable through droby" do
                test_profile = SyskitProfileTest.profile("Test")
                remote_profile = SyskitProfileTest.profile("RemoteTest")
                # We need to override the name-based resolution to force resolving a
                # different 'remote' object than a local. This checks object ID
                # registration logic
                droby_remote_marshaller.register_object(remote_profile)
                flexmock(droby_remote_marshaller)
                    .should_receive(:find_model_by_name)
                    .with("SyskitProfileTest::Test").and_return(remote_profile)
                remote, local =
                    assert_droby_compatible(SyskitProfileTest::Test, bidirectional: true)
                refute_same remote, test_profile
                assert_same local, test_profile
                # Check that droby IDs are valid
                new_remote =
                    assert_droby_compatible(SyskitProfileTest::Test, bidirectional: false)
                assert_same new_remote, remote
            end

            it "gets its cached dependency injection object invalidated "\
               "when the robot is modified" do
                profile = Profile.new
                flexmock(profile)
                    .should_receive(:invalidate_dependency_injection).at_least.once
                profile.robot.invalidate_dependency_injection
            end

            describe "#tag" do
                it "cannot be merged with another tag of the same type" do
                    srv_m = DataService.new_submodel
                    profile = Profile.new
                    profile.tag "test", srv_m
                    profile.tag "other", srv_m
                    test_task = profile.test_tag.instanciate(plan)
                    other_task = profile.other_tag.instanciate(plan)
                    refute test_task.can_merge?(other_task)
                end
                it "can be merged with another instance of itself" do
                    srv_m = DataService.new_submodel
                    profile = Profile.new
                    profile.tag "test", srv_m
                    test_task1 = profile.test_tag.instanciate(plan)
                    test_task2 = profile.test_tag.instanciate(plan)
                    assert test_task1.can_merge?(test_task2)
                end
            end

            describe "#each_definition" do
                it "enumerates the definitions" do
                    profile = Profile.new("name")
                    profile.define "test1", TaskContext
                    profile.define "test2", TaskContext
                    assert_equal %w[test1 test2], profile.each_definition.map(&:name)
                end
            end

            describe "#definition" do
                attr_reader :profile
                before do
                    @profile = Profile.new
                    task_m = TaskContext.new_submodel
                    profile.define "test", task_m
                end

                it "returns a definition object that points to the profile" do
                    req = profile.definition("test")
                    assert_kind_of Profile::Definition, req
                    assert_same profile, req.profile
                    assert_equal "test", req.name
                end

                it "raises ArgumentError if the definition does not exist" do
                    assert_raises(ArgumentError) do
                        profile.definition("does_not_exist")
                    end
                end

                it "returns a duplicate of the profile's own definition object" do
                    refute_same profile.definitions["test"], profile.definition("test")
                end

                it "returns a new object each time" do
                    refute_same profile.definition("test"), profile.definition("test")
                end

                it "does not inject the DI context" do
                    flexmock(profile).should_receive(:inject_di_context).never
                    profile.definition("test")
                end

                it "returns a non-resolved definition object in #definition" do
                    flexmock(profile).should_receive(:inject_di_context).never
                    profile.definition("test")
                end
            end

            describe Profile::Definition do
                describe "#to_action_model" do
                    attr_reader :profile
                    before do
                        @profile = Profile.new
                        task_m = TaskContext.new_submodel
                        task_m.argument :arg
                        profile.define "test", task_m
                    end

                    it "applies changes done to the requirement "\
                       "to the generated action model" do
                        d = profile.resolved_definition("test").with_arguments(arg: 10)
                        task = d.to_action_model.instanciate(plan)
                        assert_equal 10, task.arguments[:arg]
                    end
                end
            end

            describe "#resolved_definition" do
                attr_reader :profile
                before do
                    @profile = Profile.new
                    task_m = TaskContext.new_submodel
                    profile.define "test", task_m
                end

                it "returns an instance requirements object that points to the profile" do
                    req = profile.resolved_definition("test")
                    assert_same profile, req.profile
                    assert_equal "test", req.name
                end

                it "raises ArgumentError if the definition does not exist" do
                    assert_raises(ArgumentError) do
                        profile.resolved_definition("does_not_exist")
                    end
                end

                it "returns an object that is not the profile's own definition object" do
                    refute_same profile.definitions["test"],
                                profile.resolved_definition("test")
                end

                it "returns a new object each time" do
                    refute_same profile.resolved_definition("test"),
                                profile.resolved_definition("test")
                end

                it "injects the DI context" do
                    expected_req = nil
                    flexmock(profile)
                        .should_receive(:inject_di_context)
                        .with(->(req) { expected_req = req }).once
                    resolved_req = profile.resolved_definition("test")
                    assert_same expected_req, resolved_req
                end
            end

            describe "#from" do
                it "allows to setup argument forwarding" do
                    task_m = TaskContext.new_submodel
                    task_m.argument :arg
                    cmp_m = Composition.new_submodel
                    cmp_m.argument :arg
                    cmp_m.add task_m, as: "test"

                    m = Module.new
                    m.profile "Test" do
                        define "foo", cmp_m
                            .use(
                                "test" => task_m.with_arguments(
                                    arg: from(:parent_task).arg
                                )
                            )
                    end
                    cmp = syskit_stub_and_deploy(m::Test.foo_def.with_arguments(arg: 20))
                    assert_equal 20, cmp.test_child.arg
                end
            end

            describe "#from_state" do
                it "allows to setup argument forwarding" do
                    task_m = TaskContext.new_submodel
                    task_m.argument :arg
                    cmp_m = Composition.new_submodel
                    cmp_m.add task_m, as: "test"

                    state_obj = Roby::StateSpace.new
                    state_obj.arg = 30

                    m = Module.new
                    m.profile "Test" do
                        define "foo", cmp_m
                            .use(
                                "test" => task_m.with_arguments(
                                    arg: from_state(state_obj).arg
                                )
                            )
                    end
                    cmp = syskit_stub_and_deploy(m::Test.foo_def)
                    assert_equal 30, cmp.test_child.arg
                end
            end

            describe "the deployment group interface" do
                describe "#use_deployment" do
                    it "selects the deployment for deployment on the "\
                       "profile definitions" do
                        task_m = TaskContext.new_submodel(name: "Test")
                        deployment_m = syskit_stub_deployment_model(task_m)

                        profile = Profile.new
                        profile.use_deployment deployment_m
                        profile.define "test", task_m

                        # Note: so far, deployment groups are applied only when
                        # accessed through the action interface
                        syskit_run_planner_with_full_deployment do
                            task = run_planners(profile.test_def.resolve)
                            assert_kind_of deployment_m, task.execution_agent
                        end
                    end
                end

                describe "#use_ruby_tasks" do
                    before do
                        Syskit.conf.register_process_server(
                            "ruby_tasks",
                            Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader)
                        )
                    end

                    it "selects the ruby task for deployment "\
                       "on the profile definitions" do
                        task_m = RubyTaskContext.new_submodel(name: "Test")

                        profile = Profile.new
                        profile.use_ruby_tasks task_m => "test"
                        profile.define "test", task_m

                        # Note: so far, deployment groups are applied only when
                        # accessed through the action interface
                        syskit_run_planner_with_full_deployment do
                            run_planners(profile.test_def.resolve)
                        end
                    end
                end

                describe "#use_unmanaged_task" do
                    before do
                        Syskit.conf.register_process_server(
                            "unmanaged_tasks", RobyApp::UnmanagedTasksManager.new
                        )
                    end

                    after do
                        Syskit.conf.remove_process_server("unmanaged_tasks")
                    end

                    it "selects the unmanaged task for deployment "\
                       "on the profile definitions" do
                        task_m = TaskContext.new_submodel(name: "Test")

                        profile = Profile.new
                        profile.use_unmanaged_task task_m => "test"
                        profile.define "test", task_m

                        # Note: so far, deployment groups are applied only when
                        # accessed through the action interface
                        task = syskit_run_planner_with_full_deployment do
                            run_planners(profile.test_def.resolve)
                        end
                        assert_equal "unmanaged_tasks",
                                     task.execution_agent.process_server_name
                    end
                end

                describe "#use_deployments_from" do
                    before do
                        @loader = OroGen::Loaders::Base.new
                        fake_client = RobyApp::Configuration::ModelOnlyServer.new(
                            @loader
                        )
                        Syskit.conf.register_process_server("test", fake_client)
                    end

                    after do
                        Syskit.conf.remove_process_server("test")
                    end

                    it "selects all the deployments of a given project " do
                        task_m = TaskContext.new_submodel(name: "Test")
                        deployment_m = syskit_stub_deployment_model(
                            task_m, "test_deployment"
                        )

                        flexmock(@loader).should_receive(:project_model_from_name)
                                         .with("test_project")
                                         .and_return(project = flexmock)
                        flexmock(@loader).should_receive(:task_model_from_name)
                                         .and_raise(OroGen::NotFound)
                        flexmock(@loader).should_receive(:task_model_from_name)
                                         .with("Test")
                                         .and_return(task_m.orogen_model)
                        flexmock(@loader).should_receive(:deployment_model_from_name)
                                         .with("test_deployment")
                                         .and_return(deployment_m.orogen_model)
                        project.should_receive(:each_deployment)
                               .and_yield(deployment_m.orogen_model)

                        profile = Profile.new
                        profile.use_deployments_from "test_project", on: "test"
                        profile.define "test", task_m

                        # Note: so far, deployment groups are applied only when
                        # accessed through the action interface
                        syskit_run_planner_with_full_deployment do
                            task = run_planners(profile.test_def.resolve)
                            assert_kind_of deployment_m, task.execution_agent
                        end
                    end
                end

                describe "#use_group" do
                    it "registers the group's deployments for usage on the profile "\
                       "definitions" do
                        task_m = TaskContext.new_submodel(name: "Test")
                        deployment_m = syskit_stub_deployment_model(task_m)

                        group = Syskit::Models::DeploymentGroup.new
                        group.use_deployment deployment_m
                        profile = Profile.new
                        profile.use_group group
                        profile.define "test", task_m

                        # Note: so far, deployment groups are applied only when
                        # accessed through the action interface
                        syskit_run_planner_with_full_deployment do
                            task = run_planners(profile.test_def.resolve)
                            assert_kind_of deployment_m, task.execution_agent
                        end
                    end
                end
            end
        end
    end
end
