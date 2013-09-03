require 'syskit/test'

describe Syskit::Port do
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
        attr_reader :out_task, :in_task
        before do
            @out_task = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
                output_port 'out', '/double'
            end.new
            @in_task = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
            end.new
        end

        it "creates the connection directly if the argument is a port" do
            policy = Hash.new
            flexmock(out_task).should_receive(:connect_ports).once.
                with(in_task, ['out', 'in'] => policy)
            out_task.out_port.connect_to in_task.in_port, policy
        end
        it "passes through Syskit.connect if the argument is not a port" do
            policy = Hash.new
            flexmock(Syskit).should_receive(:connect).once.
                with(out_task.out_port, in_task, policy)
            out_task.out_port.connect_to in_task, policy
        end
        it "raises WrongPortConnectionDirection if the source is an input port" do
            assert_raises(Syskit::WrongPortConnectionDirection) do
                in_task.in_port.connect_to in_task.in_port
            end
        end
        it "raises WrongPortConnectionDirection if the sink is an output port" do
            assert_raises(Syskit::WrongPortConnectionDirection) do
                out_task.out_port.connect_to out_task.out_port
            end
        end
        it "raises SelfConnection if the source and sink are part of the same component" do
            assert_raises(Syskit::SelfConnection) do
                out_task.out_port.connect_to out_task.in_port
            end
        end
    end
end

describe Syskit::InputWriter do
    include Syskit::SelfTest

    it "validates the given samples if the writer is not yet accessible" do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
        end
        policy = Hash[:type => :buffer, :size => 10]
        plan.add_permanent(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer(policy)
        flexmock(Typelib).should_receive(:from_ruby).once.with([], abstract_task.in_port.type)
        port_writer.write([])
    end

    it "should be able to rebind to actual tasks that replaced the task" do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
        end
        policy = Hash[:type => :buffer, :size => 10]
        plan.add_permanent(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer(policy)
        task = syskit_deploy_task_context(task_m, 'task')
        plan.replace(abstract_task, task)

        start_task_context(task)
        assert_equal task.in_port, port_writer.resolved_port
        assert_equal task.orocos_task.port('in'), port_writer.writer.port
    end
end

describe Syskit::OutputReader do
    include Syskit::SelfTest

    it "should be able to rebind to actual tasks that replaced the task" do
        task_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        policy = Hash[:type => :buffer, :size => 10]
        plan.add_permanent(abstract_task = task_m.as_plan)
        port_reader = abstract_task.out_port.reader(policy)
        task = syskit_deploy_task_context(task_m, 'task')
        plan.replace(abstract_task, task)

        start_task_context(task)
        assert_equal task.out_port, port_reader.resolved_port
        assert_equal task.orocos_task.port('out'), port_reader.reader.port
    end
end

