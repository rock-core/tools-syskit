require 'syskit/test/self'

describe Syskit::Runtime::ConnectionManagement do
    describe "#update_required_dataflow_graph" do
        it "registers all concrete input and output connections of the given tasks" do
            source_task, task, target_task = flexmock('source'), flexmock('task'), flexmock('target')
            task.should_receive(:each_concrete_input_connection).and_yield(source_task, 'source_port', 'sink_port', (p0 = :inputs))
            task.should_receive(:each_concrete_output_connection).and_yield('source_port', 'sink_port', target_task, (p1 = :outputs))
            flexmock(Syskit::RequiredDataFlow).should_receive(:add_connections).once.
                with(source_task, task, ['source_port', 'sink_port'] => p0)
            flexmock(Syskit::RequiredDataFlow).should_receive(:add_connections).once.
                with(task, target_task, ['source_port', 'sink_port'] => p1)
            Syskit::Runtime::ConnectionManagement.new(plan).update_required_dataflow_graph([task])
        end

        it "should not add the same connection twice" do
            source_task, task = flexmock, flexmock
            task.should_receive(:each_concrete_input_connection).and_yield(source_task, 'source_port', 'sink_port', (p0 = :inputs))
            task.should_receive(:each_concrete_output_connection)
            flexmock(Syskit::RequiredDataFlow).should_receive(:add_connections).once.
                with(source_task, task, ['source_port', 'sink_port'] => p0)
            Syskit::Runtime::ConnectionManagement.new(plan).update_required_dataflow_graph([task])
        end
    end

    describe "#removed_connections_require_network_update?" do
        let(:management) { Syskit::Runtime::ConnectionManagement.new(plan) }
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
            flexmock(Syskit::ActualDataFlow, :static? => false)
            assert !management.removed_connections_require_network_update?(
                Hash[[source_task, sink_task] => ['out', 'in']])
        end

        describe "static source port" do
            before do
                flexmock(Syskit::ActualDataFlow).should_receive(:static?).
                    with(source_task.orocos_task, 'out').and_return(true)
                flexmock(Syskit::ActualDataFlow).should_receive(:static?).
                    with(sink_task.orocos_task, 'in').and_return(false)
             end

            it "returns false if the modified task is not represented in the plan" do
                assert !management.removed_connections_require_network_update?(
                    Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
            end
            it "returns false if the modified task is to be garbage-collected" do
                flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                    and_return(source_task)
                plan.unmark_mission(source_task)
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
                flexmock(Syskit::ActualDataFlow).should_receive(:static?).
                    with(source_task.orocos_task, 'out').and_return(false)
                flexmock(Syskit::ActualDataFlow).should_receive(:static?).
                    with(sink_task.orocos_task, 'in').and_return(true)
             end

            it "returns false if the modified task is not represented in the plan" do
                assert !management.removed_connections_require_network_update?(
                    Hash[[source_task.orocos_task, sink_task.orocos_task] => [['out', 'in']]])
            end
            it "returns false if the modified task is to be garbage-collected" do
                flexmock(management).should_receive(:find_setup_syskit_task_context_from_orocos_task).
                    and_return(sink_task)
                plan.unmark_mission(sink_task)
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
                Syskit::Runtime::ConnectionManagement.update(plan)
                assert sink_task.ready_for_setup?
                process_events
            end

            describe "handling of static ports" do
                it "triggers a redeployment if #removed_connections_require_network_update? returns true" do
                    expected =
                        Syskit::Flows::DataFlow.pending_changes = 
                        [flexmock, flexmock(:empty? => false), flexmock(:empty? => false)]

                    manager = Syskit::Runtime::ConnectionManagement.new(plan)
                    flexmock(manager).
                        should_receive(:removed_connections_require_network_update?).
                        and_return(true)
                    manager.update
                    assert plan.syskit_engine.forced_update?
                    assert_equal expected, Syskit::Flows::DataFlow.pending_changes
                    Syskit::Flows::DataFlow.pending_changes = nil
                end

                describe "stopped tasks" do
                    def self.common
                        it "disconnects a static source port and marks the task for reconfiguration" do
                            prepare(true, false)
                            assert Syskit::TaskContext.needs_reconfiguration?(source_task.orocos_name)
                            assert !Syskit::TaskContext.needs_reconfiguration?(sink_task.orocos_name)
                        end

                        it "disconnects a static sink port and marks the task for reconfiguration" do
                            prepare(false, true)
                            Syskit::Runtime::ConnectionManagement.update(plan)
                            assert !Syskit::TaskContext.needs_reconfiguration?(source_task.orocos_name)
                            assert Syskit::TaskContext.needs_reconfiguration?(sink_task.orocos_name)
                        end
                    end

                    describe "orocos tasks with non-static half without syskit tasks" do
                        def prepare(source_static, sink_static)
                            flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                            Syskit::ActualDataFlow.add_connections(
                                source_task.orocos_task,
                                sink_task.orocos_task,
                                ['out', 'in'] => [Hash.new, source_static, sink_static])
                            if source_static
                                plan.remove_object(sink_task)
                            else
                                plan.remove_object(source_task)
                            end
                            Syskit::Flows::DataFlow.modified_tasks << source_task << sink_task
                            Syskit::Runtime::ConnectionManagement.update(plan)
                        end

                        common
                    end

                    describe "orocos tasks with static half without syskit tasks" do
                        def prepare(source_static, sink_static)
                            flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                            Syskit::ActualDataFlow.add_connections(
                                source_task.orocos_task,
                                sink_task.orocos_task,
                                ['out', 'in'] => [Hash.new, source_static, sink_static])
                            if source_static
                                plan.remove_object(source_task)
                            else
                                plan.remove_object(sink_task)
                            end
                            Syskit::Flows::DataFlow.modified_tasks << source_task << sink_task
                            Syskit::Runtime::ConnectionManagement.update(plan)
                        end

                        common
                    end

                    describe "orocos tasks without syskit tasks" do
                        def prepare(source_static, sink_static)
                            flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).once
                            Syskit::ActualDataFlow.add_connections(
                                source_task.orocos_task,
                                sink_task.orocos_task,
                                ['out', 'in'] => [Hash.new, source_static, sink_static])
                            plan.remove_object(source_task)
                            plan.remove_object(sink_task)
                            Syskit::Flows::DataFlow.modified_tasks << source_task << sink_task
                            Syskit::Runtime::ConnectionManagement.update(plan)
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

                it "only connects ports to/from non-running tasks until the tasks are set up" do
                    sink_task.specialize
                    def sink_task.configure
                        orocos_task.create_input_port 'in2', '/double'
                    end
                    sink_task.model.orogen_model.input_port 'in2', '/double'
                    source_task.out_port.connect_to sink_task.in_port
                    source_task.out_port.connect_to sink_task.in2_port
                    flexmock(source_task.orocos_task.out).
                        should_receive(:connect_to).
                        with(sink_task.orocos_task.in, any).
                        once.globally.ordered
                    flexmock(sink_task.orocos_task, 'task').
                        should_receive(:configure).
                        once.globally.ordered.
                        pass_thru
                    flexmock(source_task.orocos_task.out).
                        should_receive(:connect_to).
                        with(->(p) { p.name == "in2" }, any).once.globally.ordered

                    assert_event_emission source_task.start_event
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
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert_equal Hash[['out', 'in'] => Hash[type: :buffer]], source_task.orocos_task[sink_task.orocos_task, Syskit::ActualDataFlow]
                    end

                    it "handles an old task still present in the plan while the new task's connection is added, both tasks not setup" do
                        plan.unmark_mission(source_task)
                        plan.add_task(new_source_task = source_task.execution_agent.task(source_task.orocos_name))
                        new_source_task.out_port.connect_to sink_task.in_port, type: :data
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert source_task.out_port.connected_to?(sink_task.in_port)
                        assert_equal Hash[['out', 'in'] => Hash[type: :data]], new_source_task.orocos_task[sink_task.orocos_task, Syskit::ActualDataFlow]
                    end

                    it "handles an old task still present in the plan while the new task's connection is added, the old task being running" do
                        syskit_configure_and_start(source_task)
                        plan.unmark_mission(source_task)
                        plan.add_mission(new_source_task = source_task.execution_agent.task(source_task.orocos_name))
                        new_source_task.conf = ['default']
                        new_source_task.should_configure_after(source_task.stop_event)
                        new_source_task.out_port.connect_to sink_task.in_port, type: :data
                        flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).with(sink_task.orocos_task.in).once.globally.ordered
                        flexmock(source_task.orocos_task.out).should_receive(:connect_to).with(sink_task.orocos_task.in, Hash[type: :data]).once.globally.ordered
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert_event_emission(new_source_task.start_event)
                        assert_equal Hash[['out', 'in'] => Hash[type: :data]], new_source_task.orocos_task[sink_task.orocos_task, Syskit::ActualDataFlow]
                    end
                end
            
                describe "sink tasks" do
                    before do
                        source_task.out_port.connect_to sink_task.in_port, type: :buffer
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert_equal Hash[['out', 'in'] => Hash[type: :buffer]], source_task.orocos_task[sink_task.orocos_task, Syskit::ActualDataFlow]
                    end

                    it "handles an old task still present in the plan while the new task's connection is added, both tasks not setup" do
                        plan.unmark_mission(sink_task)
                        plan.add_task(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                        source_task.out_port.connect_to new_sink_task.in_port, type: :data
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert source_task.out_port.connected_to?(sink_task.in_port)
                        assert_equal Hash[['out', 'in'] => Hash[type: :data]], source_task.orocos_task[new_sink_task.orocos_task, Syskit::ActualDataFlow]
                    end

                    it "handles an old task still present in the plan while the new task's connection is added, the old task being running" do
                        syskit_configure_and_start(sink_task)
                        plan.unmark_mission(sink_task)
                        plan.add_mission(new_sink_task = sink_task.execution_agent.task(sink_task.orocos_name))
                        new_sink_task.conf = ['default']
                        new_sink_task.should_configure_after(sink_task.stop_event)
                        source_task.out_port.connect_to new_sink_task.in_port, type: :data
                        flexmock(source_task.orocos_task.out).should_receive(:disconnect_from).with(sink_task.orocos_task.in).once.globally.ordered
                        flexmock(source_task.orocos_task.out).should_receive(:connect_to).with(sink_task.orocos_task.in, Hash[type: :data]).once.globally.ordered
                        Syskit::Runtime::ConnectionManagement.update(plan)
                        assert_event_emission(new_sink_task.start_event)
                        assert_equal Hash[['out', 'in'] => Hash[type: :data]], source_task.orocos_task[new_sink_task.orocos_task, Syskit::ActualDataFlow]
                    end
                end
            end

            # This is really a system test. We simulate having pending new and
            # removed connections that are queued because some tasks are not set up,
            # and then kill the tasks involved. The resulting operation should work
            # fine (i.e. not creating the dead connections)
            it "handles pending new connections that involve a dead task" do
                source_task.connect_to(sink_task)
                Syskit::Runtime::ConnectionManagement.update(plan)
                source_task.execution_agent.stop!
                # This is normally done by Runtime.update_deployment_states
                source_task.execution_agent.cleanup_dead_connections
                Syskit::Runtime::ConnectionManagement.update(plan)
            end

            it "handles pending removed connections that involve a dead task" do
                source_task.connect_to(sink_task)
                syskit_configure(source_task)
                syskit_configure(sink_task)
                Syskit::Runtime::ConnectionManagement.update(plan)

                source_task.disconnect_ports(sink_task, [['out', 'in']])
                source_task.execution_agent.stop!
                source_task.execution_agent.cleanup_dead_connections
                Syskit::Runtime::ConnectionManagement.update(plan)
            end
        end

        it "triggers a deployment if a connection to a static port is removed on an already setup task" do
            task_m = Syskit::TaskContext.new_submodel do
                input_port('in', '/double').
                    static
                output_port 'out', '/double'
            end
            source = syskit_stub_and_deploy(task_m.with_conf('source'))
            sink   = syskit_stub_and_deploy(task_m.with_conf('sink'))
            source.out_port.connect_to sink.in_port
            syskit_configure_and_start(source)
            syskit_configure_and_start(sink)
            source.out_port.disconnect_from sink.in_port

            sink_srv = sink.as_service
            Syskit::Runtime::ConnectionManagement.update(plan)
            assert plan.syskit_engine.forced_update?
            plan.syskit_engine.resolve
            refute_equal sink, sink_srv.to_task
        end
    end

    it "removes dangling connections" do
        begin
            task_m = Syskit::TaskContext.new_submodel do
                input_port('in', '/double').static
                output_port 'out', '/double'
            end
            source = Orocos::RubyTasks::TaskContext.from_orogen_model 'source', task_m.orogen_model
            sink   = Orocos::RubyTasks::TaskContext.from_orogen_model 'sink', task_m.orogen_model

            source.out.connect_to sink.in
            Syskit::ActualDataFlow.add_connections(source, sink, Hash[['out', 'in'] => [Hash.new, false, false]])
            Syskit::Runtime::ConnectionManagement.update(plan)
            assert !source.out.connected?
            assert !source.in.connected?
            assert !Syskit::ActualDataFlow.include?(source)
            assert !Syskit::ActualDataFlow.include?(sink)
        ensure
            source.dispose if source
            sink.dispose if sink
        end
    end
end

