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
end
