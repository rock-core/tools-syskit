require 'syskit/test/self'

module Syskit
    module Runtime
        module ConnectionExecutionSharedTest
            attr_reader :source, :sink, :source_task, :sink_task

            def test_it_creates_a_new_connection_when_a_new_edge_is_added_between_tasks
                flexmock(source_task.out1).should_receive(:connect_to).
                    with(sink_task.in1, Hash).once
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
            end

            def test_it_creates_a_new_connection_when_an_existing_edge_is_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
                source.out2_port.connect_to sink.in2_port
                flexmock(source_task.out2).should_receive(:connect_to).
                    with(sink_task.in2, Hash).once
                ConnectionManagement.update(plan)
            end

            def test_it_removes_a_new_connection_when_an_existing_edge_is_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                source.out2_port.connect_to sink.in2_port
                ConnectionManagement.update(plan)
                flexmock(source_task.out2).should_receive(:disconnect_from).
                    with(sink_task.in2).once
                source.out2_port.disconnect_from sink.in2_port
                ConnectionManagement.update(plan)
            end

            def test_it_removes_connections_when_edges_are_removed_updated_between_tasks
                source.out1_port.connect_to sink.in1_port
                ConnectionManagement.update(plan)
                source.remove_sink sink
                flexmock(source_task.out1).should_receive(:disconnect_from).
                    with(sink_task.in1).once
                ConnectionManagement.update(plan)
            end
        end

        describe ConnectionManagement do
            let(:dataflow_graph) { plan.task_relation_graph_for(Flows::DataFlow) }
            before do
                unplug_connection_management
            end

            describe "#update_required_dataflow_graph" do
                it "registers all concrete input and output connections of the given tasks" do
                    source_task, task, target_task = flexmock('source'), flexmock('task'), flexmock('target')
                    task.should_receive(:each_concrete_input_connection).and_yield(source_task, 'source_port', 'sink_port', (p0 = :inputs))
                    task.should_receive(:each_concrete_output_connection).and_yield('source_port', 'sink_port', target_task, (p1 = :outputs))
                    flexmock(RequiredDataFlow).should_receive(:add_connections).once.
                        with(source_task, task, ['source_port', 'sink_port'] => p0)
                    flexmock(RequiredDataFlow).should_receive(:add_connections).once.
                        with(task, target_task, ['source_port', 'sink_port'] => p1)
                    ConnectionManagement.new(plan).update_required_dataflow_graph([task])
                end

                it "should not add the same connection twice" do
                    source_task, task = flexmock, flexmock
                    task.should_receive(:each_concrete_input_connection).and_yield(source_task, 'source_port', 'sink_port', (p0 = :inputs))
                    task.should_receive(:each_concrete_output_connection)
                    flexmock(RequiredDataFlow).should_receive(:add_connections).once.
                        with(source_task, task, ['source_port', 'sink_port'] => p0)
                    ConnectionManagement.new(plan).update_required_dataflow_graph([task])
                end
            end

            describe "#removed_connections_require_network_update?" do
                let(:management) { ConnectionManagement.new(plan) }
                attr_reader :source_task, :sink_task
                before do
                    @source_task = syskit_stub_and_deploy("source") do
                        output_port 'out', '/double'
                        output_port 'state', '/int'
                    end
                    @sink_task = syskit_stub_and_deploy("sink") do
                        output_port 'state', '/int'
                        input_port 'in', '/double'
                    end
                    syskit_start_execution_agents(source_task)
                    syskit_start_execution_agents(sink_task)
                end

                it "returns false if the ports are not static" do
                    flexmock(ActualDataFlow, :static? => false)
                    assert !management.removed_connections_require_network_update?(
                        Hash[[source_task, sink_task] => ['out', 'in']])
                end

                describe "static source port" do
                    before do
                        flexmock(ActualDataFlow).should_receive(:static?).
                            with(source_task.orocos_task, 'out').and_return(true)
                        flexmock(ActualDataFlow).should_receive(:static?).
                            with(sink_task.orocos_task, 'in').and_return(false)
                     end

                    it "returns false if the modified task is not represented in the plan" do
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                    it "returns false if the modified task is to be garbage-collected" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                            and_return(source_task)
                        plan.unmark_mission_task(source_task)
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                    it "returns true if the task is already configured" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                            and_return(source_task)
                        assert management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                end

                describe "static sink port" do
                    before do
                        flexmock(ActualDataFlow).should_receive(:static?).
                            with(source_task.orocos_task, 'out').and_return(false)
                        flexmock(ActualDataFlow).should_receive(:static?).
                            with(sink_task.orocos_task, 'in').and_return(true)
                     end

                    it "returns false if the modified task is not represented in the plan" do
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                    it "returns false if the modified task is to be garbage-collected" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                            and_return(sink_task)
                        plan.unmark_mission_task(sink_task)
                        assert !management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                    it "returns true if the task is already configured" do
                        flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                            and_return(sink_task)
                        assert management.removed_connections_require_network_update?(
                            Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
                    end
                end
            end


            describe "#update" do
                describe "interaction between connections and task states" do
                    attr_reader :source_task, :sink_task
                    before do
                        @source_task = syskit_stub_and_deploy("source") do
                            output_port 'out', '/double'
                            output_port 'state', '/int'
                        end
                        @sink_task = syskit_stub_and_deploy("sink") do
                            output_port 'state', '/int'
                            input_port 'in', '/double'
                        end
                        syskit_start_execution_agents(source_task)
                        syskit_start_execution_agents(sink_task)
                    end

                    it "connects input static ports before the task gets set up" do
                        flexmock(source_task.orocos_task.port('out')).should_receive(:connect_to).once.ordered
                        flexmock(sink_task.orocos_task).should_receive(:configure).once.ordered.pass_thru
                        source_task.connect_to(sink_task)
                        assert !sink_task.ready_for_setup?, "#{sink_task} is ready_for_setup? but its inputs are not connected yet"
                        process_events
                        ConnectionManagement.update(plan)
                        assert sink_task.ready_for_setup?
                        process_events
                    end

                    describe "handling of static ports" do
                        it "triggers a redeployment if #removed_connections_require_network_update? returns true" do
                            expected = dataflow_graph.pending_changes = 
                                [Set.new, flexmock(:base, Hash.new, empty?: false), flexmock(:base, Hash.new, empty?: false)]

                            manager = ConnectionManagement.new(plan)
                            flexmock(manager).should_receive(:removed_connections_require_network_update?).
                                and_return(true)
                            flexmock(manager).should_receive(:update).once.pass_thru.ordered
                            flexmock(Syskit::NetworkGeneration::Engine).should_receive(:resolve).once.ordered
                            flexmock(manager).should_receive(:update).once.ordered
                            manager.update
                            assert_equal expected, dataflow_graph.pending_changes
                            dataflow_graph.pending_changes = nil
                        end

                        describe "stopped tasks" do
                            def self.common
                                it "disconnects a static source port and marks the task for reconfiguration" do
                                    prepare(true, false)
                                    assert TaskContext.needs_reconfiguration?(source_task.orocos_name)
                                    assert !TaskContext.needs_reconfiguration?(sink_task.orocos_name)
                                end

                                it "disconnects a static sink port and marks the task for reconfiguration" do
                                    prepare(false, true)
                                    ConnectionManagement.update(plan)
                                    assert !TaskContext.needs_reconfiguration?(source_task.orocos_name)
                                    assert TaskContext.needs_reconfiguration?(sink_task.orocos_name)
                                end
                            end

                            describe "orocos tasks with non-static half without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                                    ActualDataFlow.add_connections(
                                        source_task.orocos_task,
                                        sink_task.orocos_task,
                                        ['out', 'in'] => [Hash.new, source_static, sink_static])
                                    if source_static
                                        plan.remove_task(sink_task)
                                    else
                                        plan.remove_task(source_task)
                                    end
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end

                            describe "orocos tasks with static half without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                                    ActualDataFlow.add_connections(
                                        source_task.orocos_task,
                                        sink_task.orocos_task,
                                        ['out', 'in'] => [Hash.new, source_static, sink_static])
                                    if source_static
                                        plan.remove_task(source_task)
                                    else
                                        plan.remove_task(sink_task)
                                    end
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end

                            describe "orocos tasks without syskit tasks" do
                                def prepare(source_static, sink_static)
                                    flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                                    ActualDataFlow.add_connections(
                                        source_task.orocos_task,
                                        sink_task.orocos_task,
                                        ['out', 'in'] => [Hash.new, source_static, sink_static])
                                    plan.remove_task(source_task)
                                    plan.remove_task(sink_task)
                                    dataflow_graph.modified_tasks << source_task << sink_task
                                    ConnectionManagement.update(plan)
                                end

                                common
                            end
                        end
                    end

                    describe "handling of dynamic ports" do
                        it "waits for the tasks to be set up to connect dynamic ports" do
                            source_task.specialize
                            def source_task.configure
                                orocos_task.create_output_port 'out2', '/double'
                            end
                            source_task.model.orogen_model.output_port 'out2', '/double'
                            source_task.out2_port.connect_to sink_task.in_port
                            flexmock(source_task.orocos_task).
                                should_receive(:configure).
                                once.globally.ordered.
                                pass_thru.
                                and_return do
                                    flexmock(source_task.orocos_task.out2).
                                        should_receive(:connect_to).
                                        with(sink_task.orocos_task.in).
                                        once.globally.ordered
                                    true
                                end
                            assert_event_emission source_task.start_event
                        end

                        it "does not connect ports between two running tasks until the rest of the network is ready" do
                            syskit_configure_and_start(source_task)
                            syskit_configure_and_start(sink_task)
                            pre_operational_task = syskit_stub_and_deploy("pre_operational") do
                                output_port 'state', '/int'
                                input_port 'in', '/double'
                            end
                            pre_operational_task.specialize
                            def pre_operational_task.configure
                                orocos_task.create_output_port 'in2', '/double'
                            end
                            pre_operational_task.model.orogen_model.input_port 'in2', '/double'
                            syskit_start_execution_agents(pre_operational_task)

                            source_task.out_port.connect_to sink_task.in_port
                            source_task.out_port.connect_to pre_operational_task.in2_port
                            plug_connection_management

                            flexmock(pre_operational_task.orocos_task).
                                should_receive(:configure).
                                once.globally.ordered.
                                pass_thru
                            flexmock(source_task.orocos_task.out).
                                should_receive(:connect_to).
                                with(sink_task.orocos_task.in, any).
                                once.globally.ordered(:connections)
                            flexmock(source_task.orocos_task.out).
                                should_receive(:connect_to).
                                with(->(port) { port.name == 'in2' }, any).
                                once.globally.ordered(:connections)

                            assert_event_emission pre_operational_task.start_event
                        end
                    end

                    describe "policy update of existing connections" do
                        # These check a situation where the deployer would have spawned
                        # a new task (for reconfiguration) that would have a different
                        # policy than the existing policy. It might happen that the Roby
                        # GC would not have removed the old task and the connection
                        # management would create the new connection
                    
                        describe "source tasks" do
                            before do
                                source_task.out_port.connect_to sink_task.in_port, type: :buffer
                                ConnectionManagement.update(plan)
                                assert_equal Hash[['out', 'in'] => Hash[type: :buffer]], ActualDataFlow.edge_info(source_task.orocos_task, sink_task.orocos_task)
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, both tasks not setup" do
                                plan.unmark_mission_task(source_task)
                                plan.add(new_source_task = source_task.execution_agent.task(source_task.orocos_name))
                                new_source_task.out_port.connect_to sink_task.in_port, type: :data
                                ConnectionManagement.update(plan)
                                assert source_task.out_port.connected_to?(sink_task.in_port)
                                assert_equal Hash[['out', 'in'] => Hash[type: :data]], ActualDataFlow.edge_info(new_source_task.orocos_task, sink_task.orocos_task)
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, the old task being running" do
                                syskit_configure_and_start(source_task)
                                plan.unmark_mission_task(source_task)
                                plan.add_mission_task(new_source_task = source_task.execution_agent.task(source_task.orocos_name))
                                new_source_task.conf = ['default']
                                new_source_task.should_configure_after(source_task.stop_event)
                                new_source_task.out_port.connect_to sink_task.in_port, type: :data
                                flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).with(sink_task.orocos_task.in).once.globally.ordered
                                flexmock(source_task.orocos_task.out).should_receive(:connect_to).with(sink_task.orocos_task.in, Hash[type: :data]).once.globally.ordered
                                ConnectionManagement.update(plan)
                                assert_event_emission(new_source_task.start_event)
                                assert_equal Hash[['out', 'in'] => Hash[type: :data]], ActualDataFlow.edge_info(new_source_task.orocos_task, sink_task.orocos_task)
                            end
                        end
                    
                        describe "sink tasks" do
                            before do
                                source_task.out_port.connect_to sink_task.in_port, type: :buffer
                                ConnectionManagement.update(plan)
                                assert_equal Hash[['out', 'in'] => Hash[type: :buffer]], ActualDataFlow.edge_info(source_task.orocos_task, sink_task.orocos_task)
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, both tasks not setup" do
                                plan.unmark_mission_task(sink_task)
                                plan.add(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                                source_task.out_port.connect_to new_sink_task.in_port, type: :data
                                ConnectionManagement.update(plan)
                                assert source_task.out_port.connected_to?(sink_task.in_port)
                                assert_equal Hash[['out', 'in'] => Hash[type: :data]], ActualDataFlow.edge_info(source_task.orocos_task, new_sink_task.orocos_task)
                            end

                            it "handles an old task still present in the plan while the new task's connection is added, the old task being running" do
                                syskit_configure_and_start(sink_task)
                                plan.unmark_mission_task(sink_task)
                                plan.add_mission_task(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                                new_sink_task.conf = ['default']
                                new_sink_task.should_configure_after(sink_task.stop_event)
                                source_task.out_port.connect_to new_sink_task.in_port, type: :data
                                flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).with(sink_task.orocos_task.in).once.globally.ordered
                                flexmock(source_task.orocos_task.out).should_receive(:connect_to).with(sink_task.orocos_task.in, Hash[type: :data]).once.globally.ordered
                                ConnectionManagement.update(plan)
                                assert_event_emission(new_sink_task.start_event)
                                assert_equal Hash[['out', 'in'] => Hash[type: :data]], ActualDataFlow.edge_info(source_task.orocos_task, new_sink_task.orocos_task)
                            end
                        end
                    end
                end

                it "triggers a deployment if a connection to a static port is removed on an already setup task" do
                    task_m = TaskContext.new_submodel do
                        input_port('in', '/double').static
                        output_port 'out', '/double'
                    end
                    source = syskit_stub_and_deploy(task_m.with_conf('source'))
                    sink   = syskit_stub_and_deploy(task_m.with_conf('sink'))
                    source.out_port.connect_to sink.in_port
                    syskit_configure_and_start(source)
                    syskit_configure_and_start(sink)
                    source.out_port.disconnect_from sink.in_port

                    sink_srv = sink.as_service
                    ConnectionManagement.update(plan)
                    ConnectionManagement.update(plan)
                    refute_equal sink, sink_srv.to_task
                end

                it "detects and applies removed connections between ports, even if the two underlying tasks still have connections" do
                    source_task = syskit_stub_deploy_and_configure("source") do
                        output_port 'out1', '/double'
                        output_port 'out2', '/double'
                        output_port 'state', '/int'
                    end
                    sink_task = syskit_stub_deploy_and_configure("sink") do
                        input_port 'in1', '/double'
                        input_port 'in2', '/double'
                        output_port 'state', '/int'
                    end
                    source_task.out1_port.connect_to sink_task.in1_port
                    source_task.out2_port.connect_to sink_task.in2_port
                    ConnectionManagement.update(plan)
                    assert source_task.orocos_task.out1.connected?
                    assert source_task.orocos_task.out2.connected?

                    source_task.out2_port.disconnect_from sink_task.in2_port
                    ConnectionManagement.update(plan)
                    assert source_task.orocos_task.out1.connected?
                    assert !source_task.orocos_task.out2.connected?
                end

                it "carries the tasks over to the next cycle if there are pending connections" do
                    source_task = syskit_stub_deploy_and_configure("source")
                    sink_task = syskit_stub_deploy_and_configure("sink")

                    manager = ConnectionManagement.new(plan)
                    flexmock(manager).should_receive(:compute_connection_changes).
                        with(Set[source_task]).once.ordered.and_return([Hash.new, Hash.new])
                    flexmock(manager).should_receive(:compute_connection_changes).
                        with(Set[source_task, sink_task]).once.ordered.and_return([Hash.new, Hash.new])
                    flexmock(manager).should_receive(:apply_connection_changes).
                        and_return([flexmock(:base, Hash.new, empty?: false), flexmock(:base, Hash.new, empty?: false)])
                    dataflow_graph = plan.task_relation_graph_for(Syskit::Flows::DataFlow)
                    dataflow_graph.modified_tasks << source_task

                    manager.update
                    dataflow_graph.modified_tasks << sink_task
                    manager.update
                end
            end

            describe "connections involving finalized task" do
                attr_reader :source, :sink, :task_m, :source_orocos_task, :sink_orocos_task
                before do
                    unplug_connection_management
                    @task_m = TaskContext.new_submodel do
                        input_port 'in', '/double'
                        output_port 'out', '/double'
                    end
                    @source = syskit_stub_deploy_and_configure(task_m.with_conf('test0'))
                    @sink   = syskit_stub_deploy_and_configure(task_m.with_conf('test1'))
                    plan.add_permanent_task(source.execution_agent)
                    plan.add_permanent_task(sink.execution_agent)
                    @source_orocos_task = source.orocos_task
                    @sink_orocos_task = sink.orocos_task
                    source.out_port.connect_to sink.in_port
                    ConnectionManagement.update(plan)
                    assert dataflow_graph.modified_tasks.empty?
                end

                def assert_is_disconnected(source_alive: true, sink_alive: true)
                    assert ActualDataFlow.edges.empty?
                    if source_alive
                        assert !source_orocos_task.out.connected?
                    end
                    if sink_alive
                        assert !sink_orocos_task.in.connected?
                    end
                end

                it "successfully removes a connection from a non-finalized task and a finalized one" do
                    orocos_task = sink.orocos_task
                    plan.unmark_mission_task(sink)
                    assert_event_emission sink.stop_event
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "successfully removes a connection from a finalized task to a non-finalized one" do
                    plan.unmark_mission_task(source)
                    assert_event_emission source.stop_event
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "removes dangling connections between tasks that have been finalized" do
                    plan.unmark_mission_task(source)
                    assert_event_emission source.stop_event
                    plan.unmark_mission_task(sink)
                    assert_event_emission sink.stop_event
                    ConnectionManagement.update(plan)
                    assert_is_disconnected
                end

                it "removes connections when the source deployment is stopped" do
                    plan.unmark_permanent_task(source.execution_agent)
                    plan.unmark_mission_task(source)
                    assert_event_emission source.execution_agent.stop_event
                    ConnectionManagement.update(plan)
                    assert_is_disconnected(source_alive: false)
                end

                it "removes connections when the sink deployment is stopped" do
                    plan.unmark_permanent_task(sink.execution_agent)
                    plan.unmark_mission_task(sink)
                    assert_event_emission sink.execution_agent.stop_event
                    ConnectionManagement.update(plan)
                    assert_is_disconnected(sink_alive: false)
                end
            end
            
            it "raises if an expected input port is not present on a configured task" do
                source_m  = TaskContext.new_submodel { output_port('out', '/double') }
                sink_m    = TaskContext.new_submodel
                source = syskit_stub_deploy_and_configure(source_m)
                sink   = syskit_stub_deploy_and_configure(sink_m)
                sink.specialize
                sink.model.orogen_model.input_port 'in', '/double'
                source.out_port.connect_to sink.in_port
                e = assert_adds_roby_localized_error(PortNotFound) do
                    ConnectionManagement.update(plan)
                end
                assert_equal sink, e.failed_task
                assert_equal 'in', e.port_name
                assert_equal :input, e.port_kind
            end
            it "raises if an expected output port is not present on a configured task" do
                source_m  = TaskContext.new_submodel
                sink_m    = TaskContext.new_submodel { input_port('in', '/double') }
                source = syskit_stub_deploy_and_configure(source_m)
                sink   = syskit_stub_deploy_and_configure(sink_m)
                source.specialize
                source.model.orogen_model.output_port 'out', '/double'
                source.out_port.connect_to sink.in_port
                e = assert_adds_roby_localized_error(PortNotFound) do
                    ConnectionManagement.update(plan)
                end
                assert_equal source, e.failed_task
                assert_equal 'out', e.port_name
                assert_equal :output, e.port_kind
            end

            describe "#partition_early_late" do
                subject { ConnectionManagement.new(plan) }
                it "returns a hash for the late connections" do
                    connections = Hash[[source = flexmock, sink = flexmock] => Hash.new]
                    states = Hash[source => :RUNNING, sink => :RUNNING]
                    early, late = subject.partition_early_late(connections, states, '', ->(t) { t })
                    assert_kind_of Hash, late
                end

                it "passes connections between running tasks in the late hash" do 
                    connections = Hash[[source = flexmock, sink = flexmock] => Hash.new]
                    states = Hash[source => :RUNNING, sink => :RUNNING]
                    early, late = subject.partition_early_late(connections, states, '', ->(t) { t })
                    assert early.empty?
                    assert_equal connections, late
                end
            end

            describe "the basic behaviour" do
                it "waits for the tasks to be deployed before creating new connections" do
                    source_m = TaskContext.new_submodel do
                        output_port 'out', '/double'
                    end
                    sink_m = TaskContext.new_submodel do
                        input_port 'in', '/double'
                    end
                    source = syskit_stub_and_deploy(source_m)
                    sink   = syskit_stub_and_deploy(sink_m)
                    source.out_port.connect_to sink.in_port
                    assert(!source.execution_agent.running? && !sink.execution_agent.running?)
                    ConnectionManagement.update(plan)
                    source.execution_agent.start!
                    ConnectionManagement.update(plan)
                    assert(!sink.execution_agent.running?)
                    sink.execution_agent.start!
                    flexmock(source.orocos_task.out).should_receive(:connect_to).
                        with(sink.orocos_task.in, Hash).once
                    ConnectionManagement.update(plan)
                end

                describe "between task contexts" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port 'out1', '/double'
                            output_port 'out2', '/double'
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port 'in1', '/double'
                            input_port 'in2', '/double'
                        end
                        @source = syskit_stub_and_deploy(source_m)
                        source.execution_agent.start!
                        @source_task = source.orocos_task
                        @sink   = syskit_stub_and_deploy(sink_m)
                        sink.execution_agent.start!
                        @sink_task = sink.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end

                describe "between a composition and a task" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port 'out1', '/double'
                            output_port 'out2', '/double'
                        end
                        cmp_m = Composition.new_submodel do
                            add source_m, as: 'test'
                            export test_child.out1_port
                            export test_child.out2_port
                        end 
                        sink_m = TaskContext.new_submodel do
                            input_port 'in1', '/double'
                            input_port 'in2', '/double'
                        end
                        @source = syskit_stub_and_deploy(cmp_m)
                        source.test_child.execution_agent.start!
                        @source_task = source.test_child.orocos_task
                        @sink   = syskit_stub_and_deploy(sink_m)
                        sink.execution_agent.start!
                        @sink_task = sink.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end

                describe "between a task and a composition" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port 'out1', '/double'
                            output_port 'out2', '/double'
                        end
                        sink_m = TaskContext.new_submodel do
                            input_port 'in1', '/double'
                            input_port 'in2', '/double'
                        end
                        cmp_m = Composition.new_submodel do
                            add sink_m, as: 'test'
                            export test_child.in1_port
                            export test_child.in2_port
                        end 
                        @source = syskit_stub_and_deploy(source_m)
                        source.execution_agent.start!
                        @source_task = source.orocos_task
                        @sink   = syskit_stub_and_deploy(cmp_m)
                        sink.test_child.execution_agent.start!
                        @sink_task = sink.test_child.orocos_task
_                   end

                    include ConnectionExecutionSharedTest
                end

                describe "between two compositions" do
                    before do
                        source_m = TaskContext.new_submodel do
                            output_port 'out1', '/double'
                            output_port 'out2', '/double'
                        end
                        source_cmp_m = Composition.new_submodel do
                            add source_m, as: 'test'
                            export test_child.out1_port
                            export test_child.out2_port
                        end 
                        sink_m = TaskContext.new_submodel do
                            input_port 'in1', '/double'
                            input_port 'in2', '/double'
                        end
                        sink_cmp_m = Composition.new_submodel do
                            add sink_m, as: 'test'
                            export test_child.in1_port
                            export test_child.in2_port
                        end 
                        @source = syskit_stub_and_deploy(source_cmp_m)
                        source.test_child.execution_agent.start!
                        @source_task = source.test_child.orocos_task
                        @sink   = syskit_stub_and_deploy(sink_cmp_m)
                        sink.test_child.execution_agent.start!
                        @sink_task = sink.test_child.orocos_task
                    end

                    include ConnectionExecutionSharedTest
                end
            end
    
            describe "handling of dead deployments" do
                attr_reader :source_task, :sink_task, :source_agent, :sink_agent, :source_orocos, :sink_orocos
                before do
                    unplug_connection_management
                    task_m = Syskit::TaskContext.new_submodel do
                        input_port 'in', '/double'
                        output_port 'out', '/double'
                    end
                    @source_task = syskit_stub_deploy_configure_and_start(task_m.with_conf('source_task'))
                    @sink_task = syskit_stub_deploy_configure_and_start(task_m.with_conf('sink_task'))
                    @source_orocos = source_task.orocos_task
                    @sink_orocos = sink_task.orocos_task
                    plan.add_permanent_task(@source_agent = source_task.execution_agent)
                    plan.add_permanent_task(@sink_agent = sink_task.execution_agent)

                    source_task.out_port.connect_to sink_task.in_port
                    Syskit::Runtime::ConnectionManagement.update(plan)
                end

                # This is really a system test. We simulate having pending new and
                # removed connections that are queued because some tasks are not set up,
                # and then kill the tasks involved. The resulting operation should work
                # fine (i.e. not creating the dead connections)
                it "handles pending new connections that involve a dead task" do
                    ConnectionManagement.update(plan)
                    source_agent.stop!
                    ConnectionManagement.update(plan)
                end

                it "handles pending removed connections that involve a dead task" do
                    ConnectionManagement.update(plan)
                    source_task.disconnect_ports(sink_task, [['out', 'in']])
                    source_agent.stop!
                    ConnectionManagement.update(plan)
                end

                describe "connection add/remove hooks" do

                    it "calls them on the remaining sinks" do
                        plan.unmark_mission_task(source_task)
                        assert_event_emission source_task.stop_event do
                            source_task.stop!
                        end
                        assert Syskit::ActualDataFlow.has_edge?(source_orocos, sink_orocos)
                        flexmock(sink_task).should_receive(:removing_input_port_connection).
                            with(source_orocos, 'out', 'in').once.globally.ordered
                        flexmock(sink_task).should_receive(:removed_input_port_connection).
                            with(source_orocos, 'out', 'in').once.globally.ordered
                        source_agent.stop!
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end

                    it "calls them on the remaining sources" do
                        plan.unmark_mission_task(sink_task)
                        assert_event_emission sink_task.stop_event do
                            sink_task.stop!
                        end
                        assert Syskit::ActualDataFlow.has_edge?(source_orocos, sink_orocos)
                        flexmock(source_task).should_receive(:removing_output_port_connection).
                            with('out', sink_orocos, 'in').once.globally.ordered
                        flexmock(source_task).should_receive(:removed_output_port_connection).
                            with('out', sink_orocos, 'in').once.globally.ordered
                        sink_agent.stop!
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end
                end
            end
        end
    end
end

