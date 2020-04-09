# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Models::Port do
    describe "#to_component_port" do
        attr_reader :component_model
        before do
            @component_model = Syskit::TaskContext.new_submodel { output_port "port", "/int" }
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            port_model = Syskit::Models::Port.new(component_model, component_model.orogen_model.find_port("port"))
            flexmock(component_model).should_receive(:self_port_to_component_port).with(port_model).and_return(obj = Object.new).once
            assert_equal obj, port_model.to_component_port
        end
        it "raises ArgumentError if its model does not allow to resolve" do
            port_model = Syskit::Models::Port.new(Object.new, component_model.orogen_model.find_port("port"))
            assert_raises(ArgumentError) { port_model.to_component_port }
        end
    end

    describe "#connect_to" do
        attr_reader :out_task_m, :in_task_m
        before do
            @out_task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            @in_task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
            end
        end

        it "creates the connection directly if the argument is a port" do
            policy = {}
            flexmock(out_task_m).should_receive(:connect_ports).explicitly.once
                                .with(in_task_m, %w[out in] => policy)
            out_task_m.out_port.connect_to in_task_m.in_port, policy
        end
        it "passes through Syskit.connect if the argument is not a port" do
            policy = {}
            flexmock(Syskit).should_receive(:connect).once
                            .with(out_task_m.out_port, in_task_m, policy)
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
                output_port "out", "/double"
            end
            in_task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/int"
            end
            assert_raises(Syskit::WrongPortConnectionTypes) do
                out_task_m.out_port.connect_to in_task_m.in_port
            end
        end
    end

    describe "#can_connect_to?" do
        attr_reader :srv_out, :srv_in
        before do
            @srv_out = Syskit::DataService.new_submodel do
                output_port "int", "int"
                output_port "dbl", "double"
            end
            @srv_in = Syskit::DataService.new_submodel do
                input_port "int", "int"
                input_port "dbl", "double"
            end
        end
        it "returns true if the two ports are compatible" do
            assert srv_out.int_port.can_connect_to?(srv_in.int_port)
        end
        it "returns false if it is not a output/input connection" do
            assert !srv_out.int_port.can_connect_to?(srv_out.int_port)
            assert !srv_in.int_port.can_connect_to?(srv_in.int_port)
            assert !srv_in.int_port.can_connect_to?(srv_out.int_port)
        end
        it "returns false if it the types differ" do
            assert !srv_out.int_port.can_connect_to?(srv_in.dbl_port)
        end
        it "returns true even if the types differ" do
            assert !srv_out.int_port.can_connect_to?(srv_in.dbl_port)
        end
        it "resolves self to component port and delegate to the resolved port's can_connect_to? method" do
            component_out_port = flexmock
            component_out_port.should_receive(:can_connect_to?).with(srv_in.int_port).once
                              .and_return(true)
            flexmock(srv_out.int_port).should_receive(:try_to_component_port).and_return(component_out_port)

            assert srv_out.int_port.can_connect_to?(srv_in.int_port)
        end
        it "resolves the sink to component port before testing for compatibility" do
            flexmock(srv_in.dbl_port).should_receive(:try_to_component_port).and_return(srv_in.int_port)
            assert srv_out.int_port.can_connect_to?(srv_in.dbl_port)
        end
    end
end
