require 'syskit/test/self'

describe Syskit::Models::Port do
    describe "#to_component_port" do
        attr_reader :component_model
        before do
            @component_model = Syskit::TaskContext.new_submodel { output_port 'port', '/int' }
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            port_model = Syskit::Models::Port.new(component_model, component_model.orogen_model.find_port('port'))
            flexmock(component_model).should_receive(:self_port_to_component_port).with(port_model).and_return(obj = Object.new).once
            assert_equal obj, port_model.to_component_port
        end
        it "raises ArgumentError if its model does not allow to resolve" do
            port_model = Syskit::Models::Port.new(Object.new, component_model.orogen_model.find_port('port'))
            assert_raises(ArgumentError) { port_model.to_component_port }
        end
    end

    describe "#connect_to" do
        attr_reader :out_task_m, :in_task_m
        before do
            @out_task_m = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
                output_port 'out', '/double'
            end
            @in_task_m = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
            end
        end

        it "creates the connection directly if the argument is a port" do
            policy = Hash.new
            flexmock(out_task_m).should_receive(:connect_ports).once.
                with(in_task_m, ['out', 'in'] => policy)
            out_task_m.out_port.connect_to in_task_m.in_port, policy
        end
        it "passes through Syskit.connect if the argument is not a port" do
            policy = Hash.new
            flexmock(Syskit).should_receive(:connect).once.
                with(out_task_m.out_port, in_task_m, policy)
            out_task_m.out_port.connect_to in_task_m, policy
        end
        it "raises WrongPortConnectionDirection if the source is an input port" do
            assert_raises(Syskit::WrongPortConnectionDirection) do
                in_task_m.in_port.connect_to in_task_m.in_port
            end
        end
        it "raises WrongPortConnectionDirection if the sink is an output port" do
            assert_raises(Syskit::WrongPortConnectionDirection) do
                out_task_m.out_port.connect_to out_task_m.out_port
            end
        end
        it "raises SelfConnection if the source and sink are part of the same component" do
            assert_raises(Syskit::SelfConnection) do
                out_task_m.out_port.connect_to out_task_m.in_port
            end
        end
        it "raises WrongPortConnectionTypes if the source and sink are not of the same type" do
            out_task_m = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end
            in_task_m = Syskit::TaskContext.new_submodel do
                input_port 'in', '/int'
            end
            assert_raises(Syskit::WrongPortConnectionTypes) do
                out_task_m.out_port.connect_to in_task_m.in_port
            end
        end
    end
end


