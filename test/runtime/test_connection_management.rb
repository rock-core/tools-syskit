require 'syskit/test/self'

describe Syskit::Runtime::ConnectionManagement do
    include Syskit::Test::Self
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
        attr_reader :source_task, :sink_task
        before do
            @source_task = syskit_deploy_task_context("source", 'source') do
                output_port 'out', '/double'
            end
            @sink_task = syskit_deploy_task_context("sink", 'sink') do
                input_port 'in', '/double'
            end
        end

        it "should connect tasks only once they have been set up" do
            source_task.connect_to(sink_task)
            FlexMock.use(source_task.orocos_task.port('out')) do |mock|
                mock.should_receive(:connect_to).never
                Syskit::Runtime::ConnectionManagement.update(plan)
            end

            FlexMock.use(source_task.orocos_task.port('out')) do |mock|
                mock.should_receive(:connect_to).once
                syskit_setup_component(source_task)
                syskit_setup_component(sink_task)
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
            syskit_setup_component(source_task)
            syskit_setup_component(sink_task)
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
end
