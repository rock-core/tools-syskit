# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe PortDynamics::Trigger do
            attr_reader :trigger, :trigger_name, :period, :sample_count
            before do
                @trigger = PortDynamics::Trigger.new(
                    @trigger_name = "trigger_test",
                    @period = flexmock,
                    @sample_count = flexmock
                )
            end
            it "defines hash-compatible equality" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, period, sample_count
                )
                assert_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the name differs" do
                trigger1 = PortDynamics::Trigger.new(
                    "other_name", period, sample_count
                )
                refute_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the period differs" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, flexmock, sample_count
                )
                refute_equal Set[trigger], Set[trigger1]
            end
            it "is inequal in the hash sense if the sample_count differs" do
                trigger1 = PortDynamics::Trigger.new(
                    trigger_name, period, flexmock
                )
                refute_equal Set[trigger], Set[trigger1]
            end
        end

        describe PortDynamics do
            describe "#merge" do
                # This tests against a memory explosion regression.
                # InstanceRequirements are routinely merged against themselves,
                # thus PortDynamics too (through InstanceRequirements#dynamics).
                # This led to having the trigger array of #dynamics explode
                # after a few deployments.
                it "stays identical if merged with a duplicate of itself" do
                    dynamics0 = PortDynamics.new("port")
                    dynamics0.add_trigger "test", 1, 1
                    dynamics1 = PortDynamics.new("port")
                    dynamics1.add_trigger "test", 1, 1
                    dynamics0.merge(dynamics1)
                    assert_equal 1, dynamics0.triggers.size
                end
            end
        end

        describe DataFlowDynamics do
            attr_reader :dynamics
            before do
                @dynamics = NetworkGeneration::DataFlowDynamics.new(plan)
            end

            describe "initial port information" do
                it "uses the task's requirements as final information for a port" do
                    stub_t = stub_type "/test"
                    task_m = Syskit::TaskContext.new_submodel do
                        output_port "out", stub_t
                    end
                    req = task_m.to_instance_requirements.add_port_period("out", 0.1)
                    task = req.instanciate(plan)
                    dynamics.propagate([task])
                    assert dynamics.has_final_information_for_port?(task, "out")
                    port_dynamics = dynamics.port_info(task, "out")

                    assert_equal [PortDynamics::Trigger.new("period", 0.1, 1)],
                                 port_dynamics.triggers.to_a
                end

                describe "communication busses" do
                    before do
                        @stub_t = stub_t = stub_type "/test"
                        @bus_m = ComBus.new_submodel message_type: stub_t
                        bus_driver_m = Syskit::TaskContext.new_submodel do
                            dynamic_output_port(/\w+/, stub_t)
                        end
                        bus_driver_m.driver_for @bus_m, as: "bus"

                        @dev_m = Device.new_submodel
                        @dev_m.provides @bus_m::ClientInSrv
                        @dev_driver_m = TaskContext.new_submodel do
                            input_port "in", stub_t
                        end
                        @dev_driver_m.driver_for @dev_m, as: "dev"

                        @robot = Robot::RobotDefinition.new
                        @bus = robot.com_bus @bus_m, driver: bus_driver_m, as: "bus"
                        @device = @robot.device(
                            @dev_m, driver: @dev_driver_m, as: "dev"
                        )
                        @device.attach_to(@bus, client_to_bus: false)
                    end

                    it "uses the attached device's information as initial information "\
                       "for the bus port" do
                        @device.period 42
                        @device.burst 21
                        @device.sample_size 2

                        task = syskit_stub_and_deploy(@device)
                        bus = task.each_child.first[0]
                        dynamics.initial_task_information(bus)

                        info = dynamics.port_info(bus, "dev")
                        assert_equal 1, info.sample_size
                        triggers = info.triggers.map { |t| [t.name, t.period, t.sample_count] }
                        assert_equal ["dev", 42, 2], triggers[0]
                        assert_equal ["dev-burst", 0, 42], triggers[1]
                    end

                    it "marks the port as done" do
                        @device.period 0.1

                        task = syskit_stub_and_deploy(@device)
                        bus = task.each_child.first[0]
                        dynamics.initial_task_information(bus)
                        assert dynamics.has_final_information_for_port?(bus, "dev")
                    end
                end

                describe "master/slave deployments" do
                    before do
                        task_m = Syskit::TaskContext.new_submodel do
                            output_port "out", "/double"
                        end
                        deployment_m = Syskit::Deployment.new_submodel do
                            master = task("master", task_m.orogen_model)
                                     .periodic(0.1)
                            slave  = task "slave", task_m.orogen_model
                            slave.slave_of(master)
                        end

                        plan.add(deployment = deployment_m.new)
                        @master = deployment.task("master")
                        @slave  = deployment.task("slave")
                        dynamics.reset([@master, @slave])
                    end

                    it "resolves if called for the slave after the master" do
                        flexmock(dynamics).should_receive(:set_port_info)
                                          .with(@slave, nil, any).once
                        flexmock(dynamics).should_receive(:set_port_info)
                        dynamics.initial_information(@master)
                        dynamics.initial_information(@slave)
                        assert dynamics.has_final_information_for_task?(@master)
                        assert dynamics.has_final_information_for_task?(@slave)
                    end

                    it "resolves if called for the master after the slave" do
                        flexmock(dynamics).should_receive(:set_port_info)
                                          .with(@slave, nil, any).once
                        flexmock(dynamics).should_receive(:set_port_info)
                        dynamics.initial_information(@slave)
                        dynamics.initial_information(@master)
                        assert dynamics.has_final_information_for_task?(@master)
                        assert dynamics.has_final_information_for_task?(@slave)
                    end

                    it "resolves the slave's main trigger using the master's" do
                        dynamics.propagate([@master, @slave])
                        assert_equal 0.1, dynamics.task_info(@slave)
                                                  .minimal_period
                    end

                    it "samples the slave's port using the trigger activity" do
                        source_m = Syskit::TaskContext.new_submodel do
                            output_port("out", "/double")
                        end
                        master_m = Syskit::TaskContext.new_submodel
                        sink_m = Syskit::TaskContext.new_submodel do
                            input_port "in", "/double"
                            output_port("out", "/double").triggered_on("in")
                        end
                        deployment_m = Syskit::Deployment.new_submodel do
                            task("source", source_m.orogen_model)
                                .periodic(0.01)
                            master = task("master", master_m.orogen_model)
                                     .periodic(0.1)
                            slave  = task "slave", sink_m.orogen_model
                            slave.slave_of(master)
                        end

                        plan.add(deployment = deployment_m.new)
                        master = deployment.task("master")
                        source = deployment.task("source")
                        slave  = deployment.task("slave")
                        source.out_port.connect_to slave.in_port
                        dynamics.propagate([master, slave, source])

                        port_info = dynamics.port_info(slave, "out")
                        assert_equal 1, port_info.triggers.size
                        assert(port_info.triggers.first.sample_count > 10)
                    end
                end
            end

            describe "compute_connection_policies" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end

                    @cmp_m = Syskit::Composition.new_submodel
                    @cmp_m.add @task_m, as: "c"
                    @cmp_m.export @cmp_m.c_child.out_port

                    @dynamics = NetworkGeneration::DataFlowDynamics.new(plan)
                end

                it "computes policies and saves them in the graph's policy_graph" do
                    plan.add(task0 = @task_m.new)
                    plan.add(task1 = @task_m.new)

                    add_agents(tasks = [task0, task1])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks)

                    task0.out_port.connect_to(task1.in_port)

                    @dynamics.should_receive(:policy_for)
                             .with(task0, "out", "in", task1, nil)
                             .and_return(type: :buffer, size: 42)
                    policy_graph = @dynamics.compute_connection_policies

                    assert_equal({ type: :buffer, size: 42 },
                                 policy_graph[[task0, task1]][%w[out in]])
                end

                it "computes the policies on the concrete connections" do
                    plan.add(task = @task_m.new)
                    cmp = @cmp_m.instanciate(plan)

                    add_agents(tasks = [task, cmp.c_child])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks)

                    cmp.c_child.out_port.connect_to(task.in_port)

                    @dynamics.should_receive(:policy_for)
                             .with(cmp.c_child, "out", "in", task, nil)
                             .and_return(type: :buffer, size: 42)
                    policy_graph = @dynamics.compute_connection_policies

                    assert_equal({ type: :buffer, size: 42 },
                                 policy_graph[[cmp.c_child, task]][%w[out in]])
                end

                it "uses in-graph policies over the computed ones" do
                    plan.add(task0 = @task_m.new)
                    plan.add(task1 = @task_m.new)

                    add_agents(tasks = [task0, task1])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks)

                    task0.out_port.connect_to(task1.in_port, type: :buffer, size: 42)

                    @dynamics.should_receive(:policy_for).never
                    policy_graph = @dynamics.compute_connection_policies

                    assert_equal({ type: :buffer, size: 42 },
                                 policy_graph[[task0, task1]][%w[out in]])
                end

                it "passes the fallback policy to #policy_for if there is one" do
                    plan.add(task0 = @task_m.new)
                    plan.add(task1 = @task_m.new)

                    add_agents(tasks = [task0, task1])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks)

                    task0.out_port.connect_to(
                        task1.in_port, fallback_policy: { type: :data }
                    )

                    @dynamics.should_receive(:policy_for)
                             .with(task0, "out", "in", task1, { type: :data })
                             .and_return(type: :buffer, size: 42)

                    policy_graph = @dynamics.compute_connection_policies

                    assert_equal({ type: :buffer, size: 42 },
                                 policy_graph[[task0, task1]][%w[out in]])
                end

                it "ignores the fallback policy if there is a policy in-graph" do
                    plan.add(task0 = @task_m.new)
                    plan.add(task1 = @task_m.new)

                    add_agents(tasks = [task0, task1])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks)

                    task0.out_port.connect_to(
                        task1.in_port,
                        type: :buffer, size: 42,
                        fallback_policy: { type: :data }
                    )

                    @dynamics.should_receive(:policy_for).never
                    policy_graph = @dynamics.compute_connection_policies
                    assert_equal({ type: :buffer, size: 42 },
                                 policy_graph[[task0, task1]][%w[out in]])
                end

                it "ignores non-deployed tasks" do
                    tasks = (0...4).map { @task_m.new }
                    tasks.each { |t| plan.add(t) }
                    add_agents(tasks[0, 2])
                    flexmock(@dynamics).should_receive(:propagate).with(tasks[0, 2])
                end
            end

            describe "#policy_for" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @source_task_m = @task_m.new_submodel
                    @sink_task_m = @task_m.new_submodel
                    plan.add(@source_t = @source_task_m.new)
                    plan.add(@sink_t = @sink_task_m.new)
                    @source_t.out_port.connect_to @sink_t.in_port
                end

                it "validates that the source port exists" do
                    e = assert_raises(InternalError) do
                        @dynamics.policy_for(@source_t, "does_not_exist",
                                             "in", @sink_t, nil)
                    end
                    assert_equal "does_not_exist is not an output port "\
                                 "of #{@source_t}", e.message
                end

                it "validates that the sink port exists" do
                    e = assert_raises(InternalError) do
                        @dynamics.policy_for(@source_t, "out",
                                             "does_not_exist", @sink_t, nil)
                    end
                    assert_equal "does_not_exist is not an input port "\
                                 "of #{@sink_t}", e.message
                end

                it "returns a data connection by default" do
                    policy = @dynamics.policy_for(@source_t, "out", "in", @sink_t, nil)
                    assert_equal :data, policy[:type]
                end

                it "returns a buffer connection of size 1 if the sink's required "\
                   'connection type is "buffer"' do
                    @sink_task_m.in_port.needs_buffered_connection
                    policy = @dynamics.policy_for(@source_t, "out", "in", @sink_t, nil)
                    assert_equal :buffer, policy[:type]
                    assert_equal 1, policy[:size]
                end

                it "raises if the required connection type is unknown and "\
                   "needs_reliable_connection is not set" do
                    flexmock(@sink_task_m.in_port)
                        .should_receive(:required_connection_type).explicitly
                        .and_return(:something)
                    assert_raises(UnsupportedConnectionType) do
                        @dynamics.policy_for(@source_t, "out", "in", @sink_t, nil)
                    end
                end

                it "returns the value from compute_reliable_connection_policy if "\
                    "the sink port is marked as needs_reliable_connection" do
                    @sink_task_m.in_port.needs_reliable_connection
                    fallback_policy = flexmock
                    flexmock(@dynamics)
                        .should_receive(:compute_reliable_connection_policy)
                        .with(@source_t.out_port, @sink_t.in_port, fallback_policy)
                        .once.and_return(expected_policy = flexmock)
                    policy = @dynamics.policy_for(
                        @source_t, "out", "in", @sink_t, fallback_policy
                    )
                    assert_equal expected_policy, policy
                end
            end

            describe "#compute_reliable_connection_policy" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    @source_task_m = @task_m.new_submodel
                    @sink_task_m = @task_m.new_submodel
                    plan.add(@source_t = @source_task_m.new)
                    plan.add(@sink_t = @sink_task_m.new)
                    @source_t.out_port.connect_to @sink_t.in_port

                    @source_dynamics = PortDynamics.new("out")
                    @source_dynamics.add_trigger("test", 1, 1)
                end

                it "computes the buffer size given the source dynamics and sink "\
                   "reading latency" do
                    @dynamics.add_port_info(@source_t, "out", @source_dynamics)
                    @dynamics.done_port_info(@source_t, "out")
                    flexmock(@dynamics)
                        .should_receive(:compute_reading_latency)
                        .with(@sink_t, @sink_t.in_port)
                        .and_return(0.5)

                    flexmock(@dynamics).should_receive(:compute_buffer_policy)
                                       .with(@source_dynamics, 0.5)
                                       .and_return(expected_policy = flexmock)
                    policy = @dynamics.compute_reliable_connection_policy(
                        @source_t.out_port, @sink_t.in_port, nil
                    )
                    assert_equal expected_policy, policy
                end

                describe "fallback conditions" do
                    before do
                        @fallback_policy = { type: flexmock }
                        flexmock(@dynamics).should_receive(:compute_buffer_policy).never
                        @dynamics.add_port_info(@source_t, "out", @source_dynamics)
                    end

                    it "falls back if the port info is not final" do
                        flexmock(@dynamics).should_receive(compute_reading_latency: 0.5)

                        policy = @dynamics.compute_reliable_connection_policy(
                            @source_t.out_port, @sink_t.in_port, @fallback_policy
                        )
                        assert_equal @fallback_policy, policy
                    end

                    it "throws if the port info is not final and no fallback policy is specified" do
                        flexmock(@dynamics).should_receive(compute_reading_latency: 0.5)

                        assert_raises(SpecError) do
                            @dynamics.compute_reliable_connection_policy(
                                @source_t.out_port, @sink_t.in_port, nil
                            )
                        end
                    end

                    it "falls back if the reading latency cannot be computed" do
                        @dynamics.done_port_info(@source_t, "out")
                        flexmock(@dynamics).should_receive(compute_reading_latency: nil)

                        policy = @dynamics.compute_reliable_connection_policy(
                            @source_t.out_port, @sink_t.in_port, @fallback_policy
                        )
                        assert_equal @fallback_policy, policy
                    end

                    it "throws if the reading latency cannot be computed and no fallback policy is specified" do
                        @dynamics.done_port_info(@source_t, "out")
                        flexmock(@dynamics).should_receive(compute_reading_latency: nil)

                        assert_raises(SpecError) do
                            @dynamics.compute_reliable_connection_policy(
                                @source_t.out_port, @sink_t.in_port, nil
                            )
                        end
                    end
                end
            end

            describe "#compute_buffer_policy" do
                it "returns the queue_size corrected by the global buffer size margin" do
                    source_dynamics = flexmock(PortDynamics.new("test"))
                    source_dynamics.add_trigger("test", 1, 1)
                    source_dynamics.should_receive(:queue_size).with(0.4).and_return(20)
                    flexmock(Syskit.conf).should_receive(buffer_size_margin: 0.11)
                    assert_equal({ type: :buffer, size: 23 },
                                 @dynamics.compute_buffer_policy(source_dynamics, 0.4))
                end
            end

            describe "#compute_reading_latency" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    plan.add(@task = @task_m.new)
                    add_agents([@task])
                end

                it "returns the task's trigger latency if it is a trigger port" do
                    @task_m.in_port.trigger_port = true
                    @task.trigger_latency = 0.5
                    assert_equal(
                        0.5, @dynamics.compute_reading_latency(@task, @task.in_port)
                    )
                end

                it "returns otherwise the task's period added to its latency" do
                    @task.trigger_latency = 0.5
                    task_dynamics = PortDynamics.new("test")
                    task_dynamics.add_trigger("test", 1, 1)
                    @dynamics.add_task_info(@task, task_dynamics)
                    @dynamics.done_task_info(@task)
                    assert_equal(
                        1.5, @dynamics.compute_reading_latency(@task, @task.in_port)
                    )
                end

                it "returns nil if the task has no known period" do
                    @task.trigger_latency = 0.5
                    task_dynamics = PortDynamics.new("test")
                    @dynamics.add_task_info(@task, task_dynamics)
                    @dynamics.done_task_info(@task)
                    assert_nil @dynamics.compute_reading_latency(@task, @task.in_port)
                end

                it "returns nil if the there is no final trigger info for the task" do
                    @task.trigger_latency = 0.5
                    task_dynamics = PortDynamics.new("test")
                    task_dynamics.add_trigger("test", 1, 1)
                    @dynamics.add_task_info(@task, dynamics)
                    assert_nil @dynamics.compute_reading_latency(@task, @task.in_port)
                end
            end

            def add_agents(tasks)
                unless @agent_m
                    @agent_m = Roby::Task.new_submodel
                    @agent_m.event :ready
                end

                agents = tasks.map { @agent_m.new }
                tasks.each_with_index { |t, i| t.add_execution_agent(agents[i]) }
            end
        end
    end
end
