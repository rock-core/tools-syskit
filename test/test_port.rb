require 'syskit/test/self'

describe Syskit::Port do
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
        it "raises if the two ports have different types" do
            policy = Hash.new
            out_task = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end
            plan.add(out_task = out_task.new)
            in_task = Syskit::TaskContext.new_submodel do
                input_port 'in', '/int'
            end
            plan.add(in_task = in_task.new)
            assert_raises(Syskit::WrongPortConnectionTypes) do
                out_task.out_port.connect_to in_task.in_port, policy
            end
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

        describe "in transaction context" do
            attr_reader :task_m, :source, :sink, :transaction
            before do
                @task_m = Syskit::TaskContext.new_submodel do
                    input_port 'in', '/double'
                    output_port 'out', '/double'
                end
                plan.add(@source = task_m.new)
                plan.add(@sink = task_m.new)
                @transaction = create_transaction
            end

            it "does not modify the connections of the underlying tasks" do
                transaction[source].out_port.connect_to transaction[sink].in_port
                assert !source.out_port.connected_to?(sink.in_port)
            end
        end
    end

    describe "#disconnect_from" do
        describe "in transaction context" do
            attr_reader :task_m, :source, :sink, :transaction
            before do
                @task_m = Syskit::TaskContext.new_submodel do
                    input_port 'in', '/double'
                    output_port 'out', '/double'
                end
                plan.add(@source = task_m.new)
                plan.add(@sink = task_m.new)
                @transaction = create_transaction
            end

            it "does not modify the connections of the underlying tasks" do
                source.out_port.connect_to sink.in_port
                transaction[source].out_port.disconnect_from transaction[sink].in_port
                assert source.out_port.connected_to?(sink.in_port)
            end
        end
    end
    
    describe "#connected_to?" do
        attr_reader :task_m, :source, :sink, :transaction
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port 'in', '/double'
                output_port 'out', '/double'
            end
            plan.add(@source = task_m.new)
            plan.add(@sink = task_m.new)
        end

        it "returns true if the ports are connected" do
            source.out_port.connect_to sink.in_port
            assert source.out_port.connected_to?(sink.in_port)
        end

        it "returns false if the ports are not connected" do
            assert !source.out_port.connected_to?(sink.in_port)
        end

        it "resolves 'self' to the component port" do
            p = source.out_port
            flexmock(p).should_receive(:to_component_port).once.and_return(m = flexmock)
            m.should_receive(:connected_to?).with(sink.in_port).and_return(ret = flexmock)
            p.connected_to?(sink.in_port)
        end

        it "resolves 'in_port' to the component port" do
            p = sink.in_port
            flexmock(p).should_receive(:to_component_port).once.and_return(flexmock(component: nil, name: ''))
            # Would have been true if we were not meddling with
            # to_component_port
            assert !source.out_port.connected_to?(p)
        end
    end

    describe "handling in Hash" do
        it "can be used as a hash key" do
            task_m = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
                output_port 'out2', '/double'
            end
            plan.add(task = task_m.new)
            port0 = Syskit::Port.new(task_m.out_port, task)
            port1 = Syskit::Port.new(task_m.out_port, task)
            assert_equal 10, Hash[port0 => 10][port1]
            port2 = Syskit::Port.new(task_m.out2_port, task)
            assert_equal nil, Hash[port0 => 10][port2]
        end
    end
end

describe Syskit::InputWriter do
    it "validates the given samples if the writer is not yet accessible" do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
        end
        policy = Hash[type: :buffer, size: 10]
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer(policy)
        flexmock(Typelib).should_receive(:from_ruby).once.with([], abstract_task.in_port.type)
        port_writer.write([])
    end

    it "should be able to rebind to actual tasks that replaced the task" do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
        end
        policy = Hash[type: :buffer, size: 10]
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer(policy)
        task = syskit_stub_deploy_and_configure(task_m)
        plan.replace(abstract_task, task)

        syskit_start(task)
        assert_equal task.in_port, port_writer.resolved_port
        assert_equal task.orocos_task.port('in'), port_writer.writer.port
    end
    it "does not bind the actual writer if the port was already disconnected" do
        task_m = Syskit::TaskContext.new_submodel do
            input_port 'in', '/double'
        end
        task = syskit_stub_deploy_and_configure(task_m)
        writer = task.in_port.writer
        flexmock(writer).should_receive(:resolve).never
        writer.disconnect
        syskit_start(task)
    end
end

describe Syskit::OutputReader do
    it "should be able to rebind to actual tasks that replaced the task" do
        task_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        policy = Hash[type: :buffer, size: 10]
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_reader = abstract_task.out_port.reader(policy)
        task = syskit_stub_deploy_and_configure(task_m)
        plan.replace(abstract_task, task)

        syskit_start(task)
        assert_equal task.out_port, port_reader.resolved_port
        assert_equal task.orocos_task.port('out'), port_reader.reader.port
    end
    it "does not bind the actual reader if the port was already disconnected" do
        task_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        task = syskit_stub_deploy_and_configure(task_m)
        reader = task.out_port.reader
        flexmock(reader).should_receive(:resolve).never
        reader.disconnect
        syskit_start(task)
    end
end

