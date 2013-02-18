require 'syskit/test'

describe Syskit::Models::Port do
    include Syskit::SelfTest

    describe "#to_component_port" do
        attr_reader :component, :port
        before do
            component_model = Syskit::TaskContext.new_submodel { output_port 'port', '/int' }
            port_model = Syskit::Models::Port.new(component_model, component_model.orogen_model.find_port('port'))
            @component = component_model.new
            @port = component.port_port
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            flexmock(component).should_receive(:self_port_to_component_port).with(port).and_return(obj = Object.new).once
            assert_equal obj, port.to_component_port
        end
        it "raises ArgumentError if its model does not allow to resolve" do
            port = Syskit::Port.new(component.model.port_port, Object.new)
            assert_raises(ArgumentError) { port.to_component_port }
        end
    end

    describe "#connect_to" do
        it "creates the connection directly if the argument is a port" do
            out_task = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end.new
            in_task = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
            end.new
            policy = Hash.new
            flexmock(out_task).should_receive(:connect_ports).once.
                with(in_task, ['out', 'in'] => policy)
            out_task.out_port.connect_to in_task.in_port, policy
        end
        it "passes through Syskit.connect if the argument is not a port" do
            out_task = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end.new
            in_task = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
            end.new
            policy = Hash.new
            flexmock(Syskit).should_receive(:connect).once.
                with(out_task.out_port, in_task, policy)
            out_task.out_port.connect_to in_task, policy
        end
    end
end

describe Syskit::OutputReader do
    include Syskit::SelfTest

    it "should be able to rebind to actual tasks that replaced the task" do
        task_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        policy = Hash[:type => :buffer, :size => 10]
        plan.add(abstract_task = task_m.as_plan)
        port_reader = abstract_task.out_port.reader(policy)
        plan.add(task = task_m.new)
        stub_deployed_task 'task', task
        plan.replace(abstract_task, task)

        start_task_context(task)
        assert_equal task.out_port, port_reader.port
        assert_equal task.orocos_task.port('out'), port_reader.reader.port
    end
end

