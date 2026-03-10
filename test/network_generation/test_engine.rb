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
                    assert_equal [planning_task].to_set,
                                 Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "returns InstanceRequirementsTask tasks that finished resolution" do
                    execute do
                        planning_task.start!
                        planning_task.resolution_success_event.emit
                    end
                    assert_equal [planning_task].to_set,
                                 Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks that failed" do
                    execute { planning_task.start! }

                    expect_execution { planning_task.failed_event.emit }.to do
                        have_error_matching Roby::PlanningFailedError.match
                                                                     .with_origin(original_task)
                    end
                    assert_equal Set.new, Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks that are pending" do
                    assert_equal Set.new, Engine.discover_requirement_tasks_from_plan(plan)
                end
                it "ignores InstanceRequirementsTask tasks whose planned task has finished" do
                    task = syskit_stub_deploy_configure_and_start(simple_component_model)
                    expect_execution { task.stop! }.to { emit task.stop_event }
                    assert_equal Set.new,
                                 Engine.discover_requirement_tasks_from_plan(plan)
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
                    assert_equal [planning_task].to_set,
                                 Engine.discover_requirement_tasks_from_plan(plan)
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
                    execute { deployed.planning_task.success_event.emit }

                    syskit_stub_conf task_model, "non_default"
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
                    syskit_stub_conf task_model, "non_default"
                    deployed_reconf = syskit_deploy(task_model.with_conf("non_default"))
                    plan.add_mission_task(deployed_reconf)

                    assert_equal [deployed_task.stop_event],
                                 deployed_reconf.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                    plan.useful_tasks
                    expect_execution.garbage_collect(true).to do
                        finalize planning_task, deployed_task
                    end
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
                    # Deregister the planning task from the list of requirements
                    execute { cmp.planning_task.success_event.emit }

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

                it "does not change anything if asked to deploy an empty " \
                   "composition twice" do
                    composition_m = Syskit::Composition.new_submodel(name: "Cmp")
                    cmp1 = syskit_deploy(composition_m)
                    cmp2 = syskit_deploy(composition_m)
                    assert_same cmp1, cmp2
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
                            { %w[out in] => { type: :buffer, size: 4, init: nil } },
                            RequiredDataFlow.edge_info(cmp.source_child, cmp.sink_child)
                        )
                    end
                end
            end

            describe "master/slave setups" do
                before do
                    @task_m = task_m = TaskContext.new_submodel do
                        argument :name
                    end
                    @deployment_m = Deployment.new_submodel(name: "test") do
                        scheduled1 = task "scheduled1", task_m
                        scheduled2 = task "scheduled2", task_m
                        scheduler = task "scheduler", task_m
                        scheduled1.slave_of(scheduler)
                        scheduled2.slave_of(scheduler)
                    end

                    @configured_deployment =
                        use_deployment(@deployment_m => "prefix_").first
                end

                it "deploys slave tasks from scratch" do
                    syskit_deploy(
                        [@task_m.with_arguments(name: "1").prefer_deployed_tasks(/1/),
                         @task_m.with_arguments(name: "2").prefer_deployed_tasks(/2/)],
                        default_deployment_group: default_deployment_group
                    )

                    assert_master_slave_pattern_correct
                end

                it "deploys a slave task when another of the same deployment exists" do
                    syskit_deploy(
                        [@task_m.with_arguments(name: "1").prefer_deployed_tasks(/1/)],
                        default_deployment_group: default_deployment_group
                    )

                    initial_tasks = plan.find_tasks(@task_m).to_a
                    execution_agent = initial_tasks.first.execution_agent

                    syskit_deploy(
                        [@task_m.with_arguments(name: "1").prefer_deployed_tasks(/1/),
                         @task_m.with_arguments(name: "2").prefer_deployed_tasks(/2/)],
                        default_deployment_group: default_deployment_group
                    )

                    initial_tasks.each do |t|
                        assert plan.has_task?(t)
                    end
                    assert_master_slave_pattern_correct
                end

                it "deploys slave tasks when the deploymentc exists" do
                    deployment_task = @configured_deployment.new(plan: plan)

                    syskit_deploy(
                        [@task_m.with_arguments(name: "1").prefer_deployed_tasks(/1/),
                         @task_m.with_arguments(name: "2").prefer_deployed_tasks(/2/)],
                        default_deployment_group: default_deployment_group
                    )

                    assert_master_slave_pattern_correct(deployment_task: deployment_task)
                end

                it "deploys slave tasks when the scheduler task exists" do
                    deployment_task = @configured_deployment.new(plan: plan)
                    scheduler_task = deployment_task.task("prefix_scheduler")

                    syskit_deploy(
                        [@task_m.with_arguments(name: "1").prefer_deployed_tasks(/1/),
                         @task_m.with_arguments(name: "2").prefer_deployed_tasks(/2/)],
                        default_deployment_group: default_deployment_group
                    )

                    tasks = assert_master_slave_pattern_correct(
                        deployment_task: deployment_task
                    )
                    assert_same scheduler_task, tasks[-1]
                end

                def assert_master_slave_pattern_correct(deployment_task: nil)
                    tasks = plan.find_tasks(@task_m).sort_by(&:orocos_name)
                    assert_equal(
                        %w[prefix_scheduled1 prefix_scheduled2 prefix_scheduler],
                        tasks.map(&:orocos_name)
                    )
                    tasks[0, 2].each do |scheduled_task|
                        assert_same tasks[-1], scheduled_task.scheduler_child
                    end

                    deployment_task ||= tasks.first.execution_agent
                    tasks.each do |t|
                        assert_same deployment_task, t.execution_agent
                    end
                    tasks
                end
            end

            describe "the hooks" do
                before do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m)

                    @task_m =
                        task_m
                        .to_instance_requirements
                        .use_deployment(deployment_m)
                end
                %w[instanciation_postprocessing instanciated_network_postprocessing
                   system_network_postprocessing deployment_postprocessing
                   final_network_postprocessing].each do |name|
                    it "calls #{name}" do
                        mock = flexmock
                        Engine.send("register_#{name}") { mock.call }
                        mock.should_receive(:call).once
                        plan.add_mission_task(@task_m)
                        syskit_run_planner_with_full_deployment { deploy_current_plan }
                    end
                    it "returns a disposable that deregisters #{name}" do
                        mock = flexmock
                        Engine.send("register_#{name}") { mock.call }.dispose
                        mock.should_receive(:call).never
                        plan.add_mission_task(@task_m)
                        syskit_run_planner_with_full_deployment { deploy_current_plan }
                    end
                end
            end

            describe "capture errors during network resolution" do
                before do
                    @srv_m = Syskit::DataService.new_submodel
                    @task_m = Syskit::TaskContext.new_submodel
                    @task_m.argument :arg
                    @cmp_m = Syskit::Composition.new_submodel
                    @cmp_m.add @task_m, as: "test"
                    @cmp_m.add @srv_m, as: "other"
                    @deployment_m = syskit_stub_configured_deployment(@task_m, "task1")
                end

                describe "#resolve_system_network" do
                    it "capture the errors from the network generator instead of " \
                       "raising them" do
                        plan.add(t1 = @cmp_m.as_plan)
                        _, errors = syskit_engine.resolve_system_network(
                            [t1.planning_task],
                            capture_errors_during_network_resolution: true,
                            default_deployment_group: default_deployment_group,
                            early_deploy: true
                        )
                        assert_equal 1, errors.size
                        assert_kind_of TaskAllocationFailed,
                                       errors.first.original_exception
                    end

                    it "capture the errors from the network deployer instead of " \
                       "raising them" do
                        task2_m = Syskit::TaskContext.new_submodel
                        task2_m.provides @srv_m, as: "srv"
                        t1 = @cmp_m.use("test" => @task_m.new(arg: 1),
                                        "other" => task2_m.new).as_plan
                        plan.add(t1)
                        _, errors = syskit_engine.resolve_system_network(
                            [t1.planning_task],
                            capture_errors_during_network_resolution: true,
                            default_deployment_group: default_deployment_group,
                            early_deploy: true
                        )
                        assert_equal 1, errors.size
                        assert_kind_of MissingDeployment,
                                       errors.first.original_exception
                    end

                    it "accumulate errors from generator and deployer instead of " \
                       "raising them" do
                        not_deployed_task_m = Syskit::TaskContext.new_submodel
                        not_deployed_task_m.provides @srv_m, as: "srv"
                        @cmp_m.add @srv_m, as: "yet_another"

                        t1 = @cmp_m.use("other" => not_deployed_task_m.new).as_plan
                        plan.add(t1)
                        _, errors = syskit_engine.resolve_system_network(
                            [t1.planning_task],
                            capture_errors_during_network_resolution: true,
                            default_deployment_group: default_deployment_group,
                            early_deploy: true
                        )
                        assert_equal 2, errors.size
                        assert_kind_of TaskAllocationFailed,
                                       errors.first.original_exception
                        assert_kind_of MissingDeployment,
                                       errors[1].original_exception
                    end

                    it "goes through the generation for tasks without issues even if " \
                       "the generation fails for some of them" do
                        task2_m = Syskit::TaskContext.new_submodel
                        task2_m.provides @srv_m, as: "srv"
                        syskit_stub_configured_deployment(task2_m)
                        t1 = @cmp_m.use("test" => @task_m.new(arg: 1)).as_plan
                        t2 = @cmp_m.use("test" => @task_m.new(arg: 1),
                                        "other" => task2_m.new).as_plan
                        plan.add(t1)
                        plan.add(t2)
                        required_instances, errors = syskit_engine.resolve_system_network(
                            [t1.planning_task, t2.planning_task],
                            capture_errors_during_network_resolution: true,
                            default_deployment_group: default_deployment_group,
                            early_deploy: true
                        )
                        assert_equal 1, errors.size
                        assert_kind_of TaskAllocationFailed,
                                       errors.first.original_exception

                        assert_equal [t2.planning_task], required_instances.keys
                    end
                end

                describe "#resolve" do
                    it "handles deployment errors during final deployment resolution " \
                       "gracefully" do
                        task2_m = Syskit::TaskContext.new_submodel
                        task2_m.provides @srv_m, as: "srv"

                        t1 = @cmp_m.use("test" => @task_m.new(arg: 2),
                                        "other" => task2_m.new).as_plan
                        plan.add(t1)

                        errors = syskit_engine.resolve(
                            requirement_tasks: [t1.planning_task],
                            capture_errors_during_network_resolution: true,
                            default_deployment_group: default_deployment_group,
                            cleanup_resolution_errors: true
                        )
                        assert_equal 1, errors.size
                        assert_kind_of MissingDeployment,
                                       errors.first.original_exception
                    end


                    it "handles deployment errors during network adaption with bad new " \
                       "task" do
                        t1 = @task_m.with_arguments(arg: 1).as_plan
                        plan.add(t1)

                        t1 = t1.as_service
                        syskit_engine.resolve(
                            requirement_tasks: [t1.planning_task],
                            default_deployment_group: default_deployment_group,
                            capture_errors_during_network_resolution: true,
                            early_deploy: true,
                            cleanup_resolution_errors: true
                        )

                        new_engine = Syskit::NetworkGeneration::Engine.new(plan)
                        t2 = @task_m.with_arguments(arg: 2).as_plan
                        plan.add(t2)

                        errors = new_engine.resolve(
                            requirement_tasks: [t1.planning_task, t2.planning_task],
                            default_deployment_group: default_deployment_group,
                            capture_errors_during_network_resolution: true,
                            early_deploy: true,
                            cleanup_resolution_errors: true
                        )
                        # Both of the tasks will emit a ConflictingDeploymentAllocation
                        # with one another
                        assert_equal 2, errors.size
                        errors.each do |e|
                            assert_kind_of ConflictingDeploymentAllocation,
                                           e.original_exception
                        end
                     end
                end
            end

            describe "when scheduling tasks for reconfiguration" do
                it "ensures that the old task is garbage collected " \
                   "when child of a composition" do
                    task_m = Syskit::TaskContext.new_submodel
                    cmp_m  = Syskit::Composition.new_submodel
                    cmp_m.add task_m, as: "test"

                    syskit_stub_configured_deployment(task_m)
                    cmp = syskit_deploy(cmp_m)
                    cmp.test_child.do_not_reuse
                    original_task = cmp.test_child
                    new_cmp = syskit_deploy(cmp_m)

                    # Should have of course created a new task
                    refute_equal new_cmp.test_child, original_task
                    # Should have instanciated a new composition since the children
                    # differ
                    refute_equal new_cmp, cmp
                    # And the old tasks should be ready to garbage-collect
                    expect_execution.garbage_collect(true).to do
                        finalize cmp, original_task
                    end
                end

                it "ensures that the old task gets garbage collected when child " \
                   "of another still useful task" do
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

                    child.do_not_reuse
                    new_parent = syskit_deploy(parent_m)
                    new_child = new_parent.test_child

                    assert_equal new_parent, parent
                    refute_equal new_child, child
                    # And the old tasks should be ready to garbage-collect
                    expect_execution.garbage_collect(true).to do
                        finalize child
                    end
                end

                it "ensures that the old task gets garbage collected when child " \
                   "of a composition, itself child of a useful task" do
                    child_m = Syskit::TaskContext.new_submodel
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add child_m, as: "task"
                    parent_m = Syskit::TaskContext.new_submodel
                    parent_m.singleton_class.class_eval do
                        define_method(:instanciate) do |*args, **kw|
                            task = super(*args, **kw)
                            task.depends_on(cmp_m.instanciate(*args, **kw),
                                            role: "test")
                            task
                        end
                    end

                    syskit_stub_configured_deployment(child_m)
                    parent_m = syskit_stub_requirements(parent_m)
                    parent = syskit_deploy(parent_m)
                    child  = parent.test_child
                    child_task = child.task_child

                    child_task.do_not_reuse
                    new_parent = syskit_deploy(parent_m)
                    new_child = new_parent.test_child
                    new_child_task = new_child.task_child

                    assert_equal new_parent, parent
                    refute_equal new_child, child
                    refute_equal new_child_task, child_task
                    # And the old tasks should be ready to garbage-collect
                    expect_execution.garbage_collect(true).to do
                        finalize child, child_task
                    end
                end
            end
        end
    end
end
