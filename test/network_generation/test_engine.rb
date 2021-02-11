# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

module Syskit
    module NetworkGeneration
        describe Engine do
            include Syskit::Fixtures::SimpleCompositionModel

            attr_reader :syskit_engine, :merge_solver

            # Helper method that mocks a port accessed through
            # Orocos::TaskContext#raw_port
            def mock_raw_port(task, port_name)
                if task.respond_to?(:orocos_task)
                    task = task.orocos_task
                end

                port = Orocos.allow_blocking_calls do
                    task.raw_port(port_name)
                end
                task.should_receive(:raw_port).with(port_name).and_return(port)
                flexmock(port)
            end

            attr_reader :stub_t
            before do
                @stub_t = app.default_loader.resolve_type "/int"
                create_simple_composition_model
                plan.execution_engine.scheduler.enabled = false
                @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                @merge_solver  = flexmock(syskit_engine.merge_solver)
            end

            def work_plan
                syskit_engine.work_plan
            end

            describe ".discover_requirement_tasks_from_plan" do
                attr_reader :original_task
                attr_reader :planning_task
                attr_reader :requirements
                before do
                    plan.add_mission_task(@original_task = simple_component_model.as_plan)
                    @planning_task = original_task.planning_task
                    @requirements = planning_task.requirements
                end

                it "returns running InstanceRequirementsTask tasks" do
                    execute { planning_task.start! }
                    assert_equal [planning_task], Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "returns InstanceRequirementsTask tasks that successfully finished" do
                    execute do
                        planning_task.start!
                        planning_task.success_event.emit
                    end
                    assert_equal [planning_task], Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks that failed" do
                    execute { planning_task.start! }

                    expect_execution { planning_task.failed_event.emit }.to do
                        have_error_matching Roby::PlanningFailedError.match
                                                                     .with_origin(original_task)
                    end
                    assert_equal [], Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks that are pending" do
                    assert_equal [], Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks whose planned task has finished" do
                    task = syskit_stub_deploy_configure_and_start(simple_component_model)
                    expect_execution { task.stop! }.to { emit task.stop_event }
                    assert_equal [], Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "includes InstanceRequirementsTask tasks whose planned task have finished, but are being repaired" do
                    task = syskit_stub_deploy_configure_and_start(simple_component_model)
                    planning_task = task.planning_task
                    expect_execution do
                        task.stop!
                        repair = Roby::Tasks::Simple.new
                        task.stop_event.handle_with(repair)
                        repair.start!
                    end.to { emit task.stop_event }
                    assert_equal [planning_task], Engine.discover_requirement_tasks_from_plan(plan)
                end
            end

            describe "#compute_system_network" do
                attr_reader :original_task
                attr_reader :planning_task
                attr_reader :requirements
                before do
                    plan.add_mission_task(@original_task = simple_component_model.as_plan)
                    @planning_task = original_task.planning_task
                    @requirements = planning_task.requirements
                end

                it "saves the mapping from requirement task in real_plan to instanciated task in work_plan" do
                    flexmock(requirements).should_receive(:instanciate)
                                          .and_return(instanciated_task = simple_component_model.new)
                    mapping = syskit_engine.compute_system_network([planning_task])
                    assert_equal instanciated_task, mapping[planning_task]
                end
            end

            describe "#fix_toplevel_tasks" do
                attr_reader :original_task
                attr_reader :planning_task
                attr_reader :final_task
                attr_reader :required_instances
                before do
                    plan.add(@original_task = simple_component_model.as_plan)
                    @planning_task = original_task.planning_task
                    syskit_engine.work_plan.add_permanent_task(@final_task = simple_component_model.new)
                    @required_instances = Hash[original_task.planning_task => final_task]
                    syskit_stub_configured_deployment(simple_component_model)
                end

                it "replaces toplevel tasks by their deployed equivalent" do
                    service = original_task.as_service
                    syskit_engine.fix_toplevel_tasks(required_instances)
                    syskit_engine.work_plan.commit_transaction
                    assert_same service.task, final_task
                    assert_same final_task.planning_task, planning_task
                end

                it "filters out cross-component relations in replacement" do
                    srv_m = DataService.new_submodel { output_port "p", "/double" }
                    # This is a regression test. We basically replace a task by
                    # its reconfigured equivalent, where ports disappeared.
                    output_m = Syskit::TaskContext.new_submodel do
                        dynamic_output_port(/[ab]/, "/double")
                        dynamic_service srv_m, as: "test" do
                            provides srv_m, as: options[:name], "p" => options[:name]
                        end
                    end
                    input_m = TaskContext.new_submodel { input_port "in", "/double" }
                    plan.add(original = output_m.as_plan)
                    plan.add(input = input_m.new)

                    original.specialize
                    original.require_dynamic_service "test", as: "a", name: "a"
                    original.a_port.connect_to input.in_port

                    new = output_m.new
                    new.specialize
                    new.require_dynamic_service "test", as: "b", name: "b"
                    syskit_engine.work_plan.add_permanent_task(new)
                    work_input = syskit_engine.work_plan[input]
                    new.b_port.connect_to work_input.in_port

                    required_instances = Hash[original.planning_task => new]

                    syskit_engine.fix_toplevel_tasks(required_instances)
                    syskit_engine.work_plan.commit_transaction
                    flow_graph = plan.task_relation_graph_for(Flows::DataFlow)
                    info = flow_graph.edge_info(new, input)
                    assert_equal Hash[%w[b in] => {}], info
                end
            end

            describe "#reconfigure_tasks_on_static_port_modification" do
                it "reconfigures already-configured tasks whose static input ports have been modified" do
                    task = syskit_stub_deploy_and_configure("Task", as: "task") { input_port("in", "/double").static }
                    proxy = work_plan[task]
                    flexmock(proxy).should_receive(:transaction_modifies_static_ports?).once.and_return(true)
                    syskit_engine.reconfigure_tasks_on_static_port_modification([proxy])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal 2, tasks.size
                    tasks.delete(proxy)
                    new_task = tasks.first

                    assert_child_of proxy.stop_event, new_task.start_event,
                                    Roby::EventStructure::SyskitConfigurationPrecedence
                end

                it "does not reconfigure already-configured tasks whose static input ports have not been modified" do
                    task = syskit_stub_deploy_and_configure("Task", as: "task") { input_port("in", "/double").static }
                    proxy = work_plan[task]
                    flexmock(proxy).should_receive(:transaction_modifies_static_ports?).once.and_return(false)
                    syskit_engine.reconfigure_tasks_on_static_port_modification([proxy])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal work_plan.wrap([task]), tasks
                end

                it "does not reconfigure not-setup tasks" do
                    task = syskit_stub_and_deploy("Task") { input_port("in", "/double").static }
                    syskit_engine.reconfigure_tasks_on_static_port_modification([task])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal work_plan.wrap([task]), tasks
                end

                describe "when child of a composition" do
                    it "ensures that the existing deployment will be garbage collected" do
                        task_m = Syskit::TaskContext.new_submodel
                        cmp_m  = Syskit::Composition.new_submodel
                        cmp_m.add task_m, as: "test"

                        syskit_stub_configured_deployment(task_m)
                        cmp = syskit_deploy(cmp_m)
                        original_task = cmp.test_child
                        flexmock(task_m).new_instances.should_receive(:can_be_deployed_by?)
                                        .with(->(proxy) { proxy.__getobj__ == cmp.test_child }).and_return(false)
                        new_cmp = syskit_deploy(cmp_m)

                        # Should have instanciated a new composition since the children
                        # differ
                        refute_equal new_cmp, cmp
                        # Should have of course created a new task
                        refute_equal new_cmp.test_child, cmp.test_child
                        # And the old tasks should be ready to garbage-collect
                        assert_equal [cmp, original_task].to_set,
                                     execute { plan.static_garbage_collect.to_set }
                    end
                end

                describe "when child of a task" do
                    it "ensures that the existing deployment will be garbage collected" do
                        child_m  = Syskit::TaskContext.new_submodel
                        parent_m = Syskit::TaskContext.new_submodel
                        parent_m.singleton_class.class_eval do
                            define_method(:instanciate) do |*args, **kw|
                                task = super(*args, **kw)
                                task.depends_on(child_m.instanciate(*args, **kw),
                                                role: "test")
                                task
                            end
                        end

                        syskit_stub_configured_deployment(child_m)
                        parent_m = syskit_stub_requirements(parent_m)
                        parent = syskit_deploy(parent_m)
                        child  = parent.test_child

                        flexmock(child_m).new_instances.should_receive(:can_be_deployed_by?)
                                         .with(->(proxy) { proxy.__getobj__ == child }).and_return(false)
                        new_parent = syskit_deploy(parent_m)
                        new_child = new_parent.test_child

                        assert_equal new_parent, parent
                        refute_equal new_child, child
                        # And the old tasks should be ready to garbage-collect
                        assert_equal [child].to_set,
                                     execute { plan.static_garbage_collect.to_set }
                    end
                end
            end

            describe "#adapt_existing_deployment" do
                attr_reader :task_m, :deployment_m
                attr_reader :deployment_task, :existing_deployment_task
                # All the merges that happened during a given test
                attr_reader :applied_merge_mappings

                before do
                    task_m = @task_m = Syskit::Component.new_submodel do
                        argument :orocos_name
                        argument :conf
                    end

                    @applied_merge_mappings = {}
                    plan.add(existing_deployment_task = EngineTestStubDeployment.new(task_m))
                    @existing_deployment_task = work_plan[existing_deployment_task]
                    flexmock(syskit_engine.merge_solver)
                        .should_receive(:apply_merge_group)
                        .with(
                            lambda do |mappings|
                                applied_merge_mappings.merge!(mappings)
                                true
                            end
                        )
                        .pass_thru
                    work_plan.add(@deployment_task = EngineTestStubDeployment.new(task_m))
                end

                it "creates a new deployed task if there is not one already" do
                    task = deployment_task.task "test"
                    syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                    created_task = existing_deployment_task.created_tasks[0].last
                    assert_equal [["test", task_m, created_task]], existing_deployment_task.created_tasks
                    assert_equal Hash[task => created_task], applied_merge_mappings
                end
                it "reuses an existing deployment" do
                    existing_task = existing_deployment_task.task("test", record: false)
                    task = deployment_task.task "test"
                    syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                    assert existing_deployment_task.created_tasks.empty?
                    assert_equal Hash[task => existing_task], applied_merge_mappings
                end

                describe "there is a deployment and it cannot be reused" do
                    attr_reader :task, :existing_task
                    before do
                        @existing_task = existing_deployment_task.task("test", record: false)
                        @task = deployment_task.task "test"
                        flexmock(task).should_receive(:can_be_deployed_by?)
                                      .with(existing_task).and_return(false)
                    end

                    it "creates a new deployed task" do
                        syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                        created_task = existing_deployment_task.created_tasks[0].last
                        assert_equal [["test", task_m, created_task]], existing_deployment_task.created_tasks
                        assert_equal Hash[task => created_task], applied_merge_mappings
                    end
                    it "synchronizes the newly created task with the end of the existing one" do
                        syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                        created_task = existing_deployment_task.created_tasks[0].last
                        assert_equal [created_task.start_event],
                                     existing_task.stop_event.each_syskit_configuration_precedence(false).to_a
                    end
                    it "re-synchronizes with all the existing tasks if more than one is present at a given time" do
                        syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                        first_new_task = existing_deployment_task.created_tasks[0].last

                        work_plan.add(deployment_task = EngineTestStubDeployment.new(task_m))
                        task = deployment_task.task("test")
                        flexmock(task).should_receive(:can_be_deployed_by?)
                                      .with(first_new_task).and_return(false)
                        syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                        second_new_task = existing_deployment_task.created_tasks[1].last

                        assert_equal [first_new_task.start_event, second_new_task.start_event],
                                     existing_task.stop_event.each_syskit_configuration_precedence(false).to_a
                        assert_equal [second_new_task.start_event],
                                     first_new_task.stop_event.each_syskit_configuration_precedence(false).to_a
                    end

                    it "synchronizes with the existing tasks even if there are no current ones" do
                        flexmock(syskit_engine).should_receive(:find_current_deployed_task)
                                               .once.and_return(nil)
                        syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
                        created_task = existing_deployment_task.created_tasks[0].last
                        assert_equal [created_task.start_event],
                                     existing_task.stop_event.each_syskit_configuration_precedence(false).to_a
                    end
                end
            end

            describe "#find_current_deployed_task" do
                it "ignores garbage tasks that have not been finalized yet" do
                    component_m = Syskit::Component.new_submodel
                    plan.add(task0 = component_m.new)
                    flexmock(task0).should_receive(can_finalize?: false)
                    plan.add(task1 = component_m.new)
                    task1.should_configure_after(task0.stop_event)
                    execute { plan.garbage_task(task0) }
                    task0 = syskit_engine.work_plan[task0]
                    task1 = syskit_engine.work_plan[task1]
                    assert_equal task1, syskit_engine.find_current_deployed_task([task0, task1])
                end

                it "ignores all non-reusable tasks" do
                    component_m = Syskit::Component.new_submodel
                    plan.add(task0 = component_m.new)
                    plan.add(task1 = component_m.new)
                    task1.should_configure_after(task0.stop_event)
                    task0.do_not_reuse
                    task1.do_not_reuse
                    task0 = syskit_engine.work_plan[task0]
                    task1 = syskit_engine.work_plan[task1]
                    assert_nil syskit_engine.find_current_deployed_task([task0, task1])
                end
            end

            describe "#finalize_deployed_tasks" do
                it "creates a transaction proxy of the already existing tasks and deployments" do
                    deployment_m = create_deployment_model(task_count: 1)
                    existing_deployment, =
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])
                    add_deployment_and_tasks(work_plan, deployment_m, %w[task0])

                    selected_deployments, =
                        syskit_engine.finalize_deployed_tasks

                    assert_equal [work_plan[existing_deployment]],
                                 selected_deployments.to_a
                end

                it "clears the deployments that are not in the plan" do
                    deployment_m = create_deployment_model(task_count: 1)
                    add_deployment_and_tasks(plan, deployment_m, %w[task0])

                    selected_deployments, =
                        syskit_engine.finalize_deployed_tasks
                    assert selected_deployments.empty?
                end

                it "creates a new deployment if it is added to the plan" do
                    deployment_m = create_deployment_model(task_count: 1)
                    add_deployment_and_tasks(plan, deployment_m, %w[task0])
                    deployment_m2 = create_deployment_model(task_count: 2)
                    required_deployment, =
                        add_deployment_and_tasks(work_plan, deployment_m2, %w[task0 task1])

                    selected_deployments, selected_deployed_tasks =
                        syskit_engine.finalize_deployed_tasks

                    assert_equal [required_deployment], selected_deployments.to_a
                    selected_deployed_tasks.each do |t|
                        assert_equal t.execution_agent, required_deployment
                    end
                end

                it "updates an existing deployment, proxying the existing tasks and creating new ones" do
                    deployment_m = create_deployment_model(task_count: 3)
                    existing_deployment, (task0, task1) =
                        add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])
                    required_deployment, (required0, task2) =
                        add_deployment_and_tasks(work_plan, deployment_m, %w[task0 task2])

                    selected_deployments, selected_deployed_tasks =
                        syskit_engine.finalize_deployed_tasks

                    expected_deployment = work_plan[existing_deployment]
                    assert_equal [expected_deployment], selected_deployments.to_a

                    task2 = work_plan.find_local_tasks
                                     .with_arguments(orocos_name: "task2").first
                    assert task2
                    refute task2.transaction_proxy?

                    assert_equal [work_plan[task0], work_plan[task1], task2].to_set,
                                 expected_deployment.each_executed_task.to_set
                    assert_equal [work_plan[task0], task2].to_set,
                                 selected_deployed_tasks.to_set
                end

                it "maintains the dependencies" do
                    deployment_m = create_deployment_model(task_count: 2)
                    existing_deployment, (existing0, existing1) =
                        add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])

                    required_deployment, (required0, required1) =
                        add_deployment_and_tasks(work_plan, deployment_m, %w[task0 task1])

                    existing0.depends_on(existing1)
                    selected_deployments, selected_deployed_tasks =
                        syskit_engine.finalize_deployed_tasks

                    assert work_plan[existing0].depends_on?(work_plan[existing1])
                end

                it "maintains the dependencies with two or more layers" do
                    deployment_m = create_deployment_model(task_count: 3)
                    _, (existing0,) =
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])

                    _, (required0, required1, required2) =
                        add_deployment_and_tasks(work_plan, deployment_m, %w[task0 task1 task2])

                    required0.depends_on required2
                    required1.depends_on required2

                    selected_deployments, selected_deployed_tasks =
                        syskit_engine.finalize_deployed_tasks

                    required2 = work_plan[existing0].children.first
                    assert_equal "task2", required2.orocos_name
                    assert required2.each_parent_task
                                    .find { |t| t.orocos_name == "task1" }
                end

                it "raises if there is a repeated deployment" do
                    deployment_m = create_deployment_model(task_count: 1)
                    add_deployment_and_tasks(plan, deployment_m, %w[task0])
                    add_deployment_and_tasks(plan, deployment_m, %w[task0])
                    add_deployment_and_tasks(work_plan, deployment_m, %w[task0])

                    assert_raises Syskit::InternalError do
                        syskit_engine.finalize_deployed_tasks
                    end
                end

                def create_deployment_model(task_count:)
                    task_m = (0...task_count).map { TaskContext.new_submodel }
                    (@created_task_models ||= []).concat(task_m)

                    Deployment.new_submodel do
                        task_m.each_with_index do |m, i|
                            task "task#{i}", m.orogen_model
                        end
                    end
                end

                def add_deployment_and_tasks(plan, deployment_m, task_names)
                    plan.add(deployment_task = deployment_m.new)
                    tasks = task_names.map { |name| deployment_task.task(name) }
                    [deployment_task, tasks]
                end
            end

            describe "synthetic tests" do
                it "deploys a mission as mission" do
                    task_model = Syskit::TaskContext.new_submodel
                    syskit_stub_configured_deployment(task_model, "task")
                    plan.add_mission_task(original_task = task_model.as_plan)
                    deployed = syskit_deploy(original_task, add_mission: false)
                    assert plan.mission_task?(deployed)
                end

                it "deploys a permanent task as permanent" do
                    task_model = Syskit::TaskContext.new_submodel
                    syskit_stub_configured_deployment(task_model, "task")
                    plan.add_permanent_task(original_task = task_model.as_plan)
                    deployed = syskit_deploy(original_task, add_mission: false)
                    assert plan.permanent_task?(deployed)
                end

                it "reconfigures a child task if needed" do
                    task_model = Syskit::TaskContext.new_submodel
                    composition_model = Syskit::Composition.new_submodel do
                        add task_model, as: "child"
                    end
                    syskit_stub_configured_deployment(task_model, "task")

                    deployed = syskit_deploy(composition_model)
                    # This deregisters the task from the list of requirements in the
                    # syskit engine
                    execute { plan.remove_task(deployed.planning_task) }

                    new_deployed = syskit_deploy(
                        composition_model.use("child" => task_model.with_conf("non_default"))
                    )

                    assert_equal(["non_default"], new_deployed.child_child.conf)
                    assert_equal [deployed.child_child.stop_event],
                                 new_deployed.child_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                end

                it "reconfigures a toplevel task if its configuration changed" do
                    task_model = Syskit::TaskContext.new_submodel
                    syskit_stub_configured_deployment(task_model, "task")

                    deployed_task = syskit_deploy(task_model)
                    planning_task = deployed_task.planning_task
                    plan.unmark_mission_task(deployed_task)
                    deployed_reconf = syskit_deploy(task_model.with_conf("non_default"))
                    plan.add_mission_task(deployed_reconf)

                    assert_equal [deployed_task.stop_event],
                                 deployed_reconf.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                    plan.useful_tasks
                    assert_equal([planning_task, deployed_task].to_set,
                                 execute { plan.static_garbage_collect.to_set })
                    assert(["non_default"], deployed_reconf.conf)
                end

                it "reconfigures tasks using the should_reconfigure_after relation" do
                    task_model = Syskit::TaskContext.new_submodel
                    composition_model = Syskit::Composition.new_submodel do
                        add task_model, as: "child"
                    end
                    syskit_stub_configured_deployment(task_model, "task")

                    cmp, = syskit_deploy(composition_model.use("child" => task_model))
                    child = cmp.child_child.to_task
                    child.do_not_reuse
                    execute { plan.remove_task(cmp.planning_task) }

                    new_cmp, = syskit_deploy(composition_model.use("child" => task_model))
                    new_child = new_cmp.child_child

                    assert_equal [child.stop_event],
                                 new_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                end

                it "does not change anything if asked to deploy the same composition twice" do
                    task_model = Syskit::TaskContext.new_submodel
                    composition_model = Syskit::Composition.new_submodel do
                        add task_model, as: "child"
                    end
                    syskit_stub_configured_deployment(task_model, "task")

                    syskit_deploy(composition_model.use("child" => task_model))
                    plan.execution_engine.garbage_collect
                    plan_copy, mappings = plan.deep_copy

                    syskit_engine.resolve(
                        default_deployment_group: default_deployment_group
                    )
                    plan.execution_engine.garbage_collect
                    diff = plan.find_plan_difference(plan_copy, mappings)
                    assert !diff, diff.to_s
                end

                it "applies connections from compositions to the final plan" do
                    task_model = Syskit::TaskContext.new_submodel do
                        output_port "out", "/double"
                    end
                    composition_model = Syskit::Composition.new_submodel do
                        add task_model, as: "child"
                        export child_child.out_port
                    end
                    syskit_stub_configured_deployment(task_model, "task")
                    cmp, = syskit_deploy(composition_model)
                    assert_equal({ %w[out out] => {} },
                                 cmp.child_child[cmp, Syskit::Flows::DataFlow])
                end

                it "sets a task's fullfilled model only for the arguments that are explicitely set in the toplevel requirements" do
                    task_m = Syskit::TaskContext.new_submodel
                    task_m.argument :arg0
                    task = syskit_stub_and_deploy(
                        task_m.with_arguments(
                            arg0: flexmock(evaluate_delayed_argument: 10)
                        )
                    )
                    assert_equal({}, task.explicit_fullfilled_model.last)
                end

                it "sets a task's fullfilled model only from the toplevel requirements" do
                    # This tests checks that it is possible to have a toplevel task
                    # (i.e. an explicitely required task) whose configuration is let
                    # loose, and then let the rest of the network "decide" the actual
                    # configuration
                    #
                    # It catches a bug in the setting of #fullfilled_model, that was
                    # moved to InstanceRequirements#instanciate but really should be in
                    # Engine#instanciate as the "requirements" due to e.g. composition
                    # membership is set through the relation graph.
                    task_m = Syskit::TaskContext.new_submodel
                    task_m.argument :arg0
                    task_m.argument :arg1
                    syskit_stub_configured_deployment(task_m)
                    task = syskit_deploy(task_m.with_arguments(arg0: 10))
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add(task_m, as: "test").with_arguments(arg1: 20)
                    syskit_deploy(cmp_m)
                    assert_equal Hash[arg0: 10], task.explicit_fullfilled_model.last
                end

                describe "com bus handling" do
                    attr_reader :combus_m, :combus_driver_m, :device_m, :device_driver_m
                    attr_reader :bus, :dev

                    before do
                        @combus_m = Syskit::ComBus.new_submodel message_type: "/int"
                        @combus_driver_m = Syskit::TaskContext.new_submodel do
                            input_port "root_bus_in", "/double"
                            dynamic_output_port(/.*/, "/int")
                        end
                        combus_driver_m.provides combus_m, as: "driver"

                        @device_m = Syskit::Device.new_submodel
                        @device_driver_m = Syskit::TaskContext.new_submodel { input_port "bus_in", "/int" }
                        device_driver_m.provides combus_m.client_in_srv, as: "bus"
                        device_driver_m.provides device_m, as: "driver"

                        @bus = robot.com_bus combus_m, as: "bus"
                        @dev = robot.device device_m, as: "dev"
                        dev.attach_to(bus, client_to_bus: false)
                    end

                    def deploy_dev_and_bus
                        syskit_stub_deployment_model(device_driver_m)
                        syskit_stub_deployment_model(combus_driver_m)
                        dev_driver = syskit_stub_and_deploy(dev)
                        bus_driver = plan.find_tasks(combus_driver_m).with_parent(dev_driver).first
                        plan.add_mission_task(dev_driver)
                        unplug_connection_management
                        syskit_start_execution_agents(bus_driver)
                        syskit_start_execution_agents(dev_driver)
                        plug_connection_management
                        [dev_driver, bus_driver]
                    end

                    it "specifies the connections between the bus and device" do
                        dev_driver, bus_driver = deploy_dev_and_bus
                        assert bus_driver.dev_port.connected_to?(dev_driver.bus_in_port)
                    end

                    it "synchronizes the startup of communication busses and their supported devices" do
                        dev_driver, bus_driver = deploy_dev_and_bus

                        bus_driver.orocos_task.local_ruby_task
                                  .create_output_port("dev", "/int")
                        flexmock(bus_driver.orocos_task, "bus")
                            .should_receive(:start).once.pass_thru
                            .globally.ordered(:bus_startup)
                        mock_raw_port(bus_driver, "dev")
                            .should_receive(:connect_to).once.pass_thru
                            .globally.ordered(:bus_startup)
                        flexmock(dev_driver.orocos_task, "dev")
                            .should_receive(:configure).once.pass_thru
                            .globally.ordered

                        syskit_configure(bus_driver)
                        capture_log(bus_driver, :info) do
                            capture_log(dev_driver, :info) do
                                expect_execution.scheduler(true).to do
                                    emit bus_driver.start_event, dev_driver.start_event
                                end
                            end
                        end
                    end

                    it "supports busses-on-busses" do
                        root_combus_m = Syskit::ComBus.new_submodel(
                            message_type: "/double"
                        )
                        root_combus_driver_m = Syskit::TaskContext.new_submodel do
                            dynamic_output_port(/.*/, "/double")
                        end
                        root_combus_driver_m.provides root_combus_m, as: "driver"
                        root_bus = robot.com_bus root_combus_m, as: "root_bus"
                        @combus_driver_m.provides root_combus_m::ClientInSrv, as: "root_client"
                        @bus.attach_to(root_bus, client_to_bus: false)
                        syskit_stub_deployment_model(root_combus_driver_m)
                        _, bus_task = deploy_dev_and_bus

                        bus_child, = bus_task.each_child.to_a.first
                        assert bus_child
                        assert_equal root_bus, bus_child.arguments[:driver_dev]
                    end
                end

                describe "merging compositions" do
                    it "does not merge compositions with an already deployed one that differs only by the underlying task's service" do
                        srv_m = Syskit::DataService.new_submodel do
                            output_port "out", "/double"
                        end
                        task_m = Syskit::TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        task_m.provides srv_m, { "out" => "out1" }, as: "out1"
                        task_m.provides srv_m, { "out" => "out2" }, as: "out2"
                        cmp_m = Syskit::Composition.new_submodel
                        cmp_m.add srv_m, as: "test"
                        cmp_m.export cmp_m.test_child.out_port

                        syskit_stub_configured_deployment(task_m, "deployed-task")
                        cmp1 = syskit_deploy(cmp_m.use(task_m.out1_srv))
                        cmp2 = syskit_deploy(cmp_m.use(task_m.out2_srv))
                        refute_same cmp1, cmp2
                    end

                    it "does merge compositions regardless of the existence of an externally added dependency relation" do
                        srv_m = Syskit::DataService.new_submodel do
                            output_port "out", "/double"
                        end
                        task_m = Syskit::TaskContext.new_submodel do
                            output_port "out1", "/double"
                            output_port "out2", "/double"
                        end
                        task_m.provides srv_m, { "out" => "out1" }, as: "out1"
                        task_m.provides srv_m, { "out" => "out2" }, as: "out2"
                        cmp_m = Syskit::Composition.new_submodel
                        cmp_m.add srv_m, as: "test"
                        cmp_m.export cmp_m.test_child.out_port

                        syskit_stub_configured_deployment(task_m, "deployed-task")
                        cmp1 = syskit_deploy(cmp_m.use(task_m.out1_srv))
                        cmp2 = cmp_m.use(task_m.out2_srv).as_plan
                        cmp1.depends_on cmp2
                        cmp2_srv = cmp2.as_service
                        execute { cmp2.planning_task.start! }
                        syskit_deploy
                        assert_equal Set[cmp1, cmp2, cmp2_srv.task], plan.find_tasks(cmp_m).to_set
                    end
                end

                describe "connection policies" do
                    before do
                        @source_task_m = Syskit::TaskContext.new_submodel do
                            output_port "out", "/double"
                            periodic 0.1
                        end
                        @sink_task_m = Syskit::TaskContext.new_submodel do
                            input_port "in", "/double"
                            periodic 0.1
                        end
                        syskit_stub_configured_deployment(@source_task_m, "source")
                        syskit_stub_configured_deployment(@sink_task_m, "sink")

                        @cmp_m = Syskit::Composition.new_submodel
                        @cmp_m.add @source_task_m, as: "source"
                        @cmp_m.add @sink_task_m, as: "sink"
                    end

                    it "propagates an explicitly specified policy to the connections" do
                        @cmp_m.source_child.out_port.connect_to(
                            @cmp_m.sink_child.in_port, type: :buffer, size: 20
                        )
                        cmp = syskit_deploy(@cmp_m, compute_policies: true)
                        syskit_configure(cmp)

                        assert_equal(
                            { %w[out in] => { type: :buffer, size: 20 } },
                            RequiredDataFlow.edge_info(cmp.source_child, cmp.sink_child)
                        )
                    end

                    it "propagates a computed policy to the connections" do
                        @sink_task_m.in_port.needs_reliable_connection
                        @cmp_m.source_child.out_port.connect_to(
                            @cmp_m.sink_child.in_port
                        )
                        cmp = syskit_deploy(@cmp_m, compute_policies: true)
                        syskit_configure(cmp)

                        assert_equal(
                            { %w[out in] => { type: :buffer, size: 4 } },
                            RequiredDataFlow.edge_info(cmp.source_child, cmp.sink_child)
                        )
                    end
                end
            end
        end

        class EngineTestStubDeployment < Roby::Task
            attr_reader :tasks
            attr_reader :created_tasks

            def initialize(task_m, **arguments)
                super(**arguments)
                @task_m = task_m
                @created_tasks = []
                @tasks = {}
            end

            event :ready

            define_method :task do |task_name, task_model = nil, record: true|
                task = @task_m.new(orocos_name: task_name)
                if record
                    @created_tasks << [task_name, task_model, task]
                end
                task.executed_by self
                task
            end
        end
    end
end
