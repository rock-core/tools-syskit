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

            it "should connect tasks only once they have been set up" do
                source_task.connect_to(sink_task)
                FlexMock.use(source_task.orocos_task.port('out')) do |mock|
                    mock.should_receive(:connect_to).never
                    Syskit::Runtime::ConnectionManagement.update(plan)
                end

                FlexMock.use(source_task.orocos_task.port('out')) do |mock|
                    mock.should_receive(:connect_to).once
                    syskit_configure(source_task)
                    syskit_configure(sink_task)
                    Syskit::Runtime::ConnectionManagement.update(plan)
                end
            end

            # This is really a system test. We simulate having pending new and
            # removed connections that are queued because some tasks are not set up,
            # and then kill the tasks involved. The resulting operation should work
            # fine (i.e. not creating the dead connections)
            it "should ignore pending new connections that involve a dead task" do
                source_task.connect_to(sink_task)
                Syskit::Runtime::ConnectionManagement.update(plan)
                source_task.execution_agent.stop!
                # This is normally done by Runtime.update_deployment_states
                source_task.execution_agent.cleanup_dead_connections
                Syskit::Runtime::ConnectionManagement.update(plan)
            end

            it "should ignore pending removed connections that involve a dead task" do
                source_task.connect_to(sink_task)
                syskit_configure(source_task)
                syskit_configure(sink_task)
                Syskit::Runtime::ConnectionManagement.update(plan)

                source_task.disconnect_ports(sink_task, [['out', 'in']])
                FlexMock.use(Syskit::Runtime::ConnectionManagement) do |mock|
                    mock.new_instances.should_receive(:apply_connection_changes).at_least.once.and_throw(:cancelled)
                    Syskit::Runtime::ConnectionManagement.update(plan)
                    source_task.execution_agent.stop!
                    # This is normally done by Runtime.update_deployment_states
                    source_task.execution_agent.cleanup_dead_connections
                end
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
end

