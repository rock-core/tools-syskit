# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Port do
    describe "#to_component_port" do
        attr_reader :component, :port
        before do
            component_model = Syskit::TaskContext.new_submodel do
                output_port "port", "/int"
            end
            @component = component_model.new
            @port = component.port_port
        end

        it "calls self_port_to_component_port on its component model to resolve itself" do
            flexmock(component).should_receive(:self_port_to_component_port)
                               .with(port).and_return(obj = Object.new).once
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
                input_port "in", "/double"
                output_port "out", "/double"
            end.new
            @in_task = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
            end.new
        end

        it "creates the connection directly if the argument is a port" do
            policy = {}
            flexmock(out_task).should_receive(:connect_ports).once
                              .with(in_task, %w[out in] => policy)
            out_task.out_port.connect_to in_task.in_port, policy
        end

        it "raises if the two ports have different types" do
            policy = {}
            out_task = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            plan.add(out_task = out_task.new)
            in_task = Syskit::TaskContext.new_submodel do
                input_port "in", "/int"
            end
            plan.add(in_task = in_task.new)
            assert_raises(Syskit::WrongPortConnectionTypes) do
                out_task.out_port.connect_to in_task.in_port, policy
            end
        end
        it "passes through Syskit.connect if the argument is not a port" do
            policy = {}
            flexmock(Syskit).should_receive(:connect).once
                            .with(out_task.out_port, in_task, policy)
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
        it "raises SelfConnection if the source and sink are part "\
           "of the same component" do
            assert_raises(Syskit::SelfConnection) do
                out_task.out_port.connect_to out_task.in_port
            end
        end

        describe "in transaction context" do
            attr_reader :task_m, :source, :sink, :transaction
            before do
                @task_m = Syskit::TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
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
                    input_port "in", "/double"
                    output_port "out", "/double"
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
                input_port "in", "/double"
                output_port "out", "/double"
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
            m.should_receive(:connected_to?).with(sink.in_port).and_return(flexmock)
            p.connected_to?(sink.in_port)
        end

        it "resolves 'in_port' to the component port" do
            p = sink.in_port
            flexmock(p).should_receive(:to_component_port).once
                       .and_return(flexmock(component: nil, name: ""))
            # Would have been true if we were not meddling with
            # to_component_port
            assert !source.out_port.connected_to?(p)
        end
    end

    describe "handling in Hash" do
        it "can be used as a hash key" do
            task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
                output_port "out2", "/double"
            end
            plan.add(task = task_m.new)
            port0 = Syskit::Port.new(task_m.out_port, task)
            port1 = Syskit::Port.new(task_m.out_port, task)
            assert_equal 10, Hash[port0 => 10][port1]
            port2 = Syskit::Port.new(task_m.out2_port, task)
            assert_nil Hash[port0 => 10][port2]
        end
    end
end

describe Syskit::InputWriter do
    attr_reader :task_m
    before do
        @task_m = Syskit::TaskContext.new_submodel do
            input_port "in", "/double"
            dynamic_input_port(/in\d/, "/double")
        end
    end

    it "resolves the writer" do
        task = syskit_stub_deploy_and_configure(task_m)
        port_writer = task.in_port.writer
        syskit_wait_ready(port_writer, component: task)
        assert_equal task.in_port, port_writer.resolved_port
        assert_equal Orocos.allow_blocking_calls { task.orocos_task.port("in") },
                     port_writer.writer.port
    end
    it "waits for the underlying component to be configured if the port is dynamic" do
        in_srv_m = Syskit::DataService.new_submodel do
            input_port "in", "/double"
        end
        @task_m.class_eval do
            def configure
                super
                Orocos.allow_blocking_calls do
                    orocos_task.create_input_port "in2", "/double"
                end
            end
            dynamic_service in_srv_m, as: "in" do
                provides in_srv_m, "in" => "in2"
            end
        end

        cmp_m = Syskit::Composition.new_submodel
        cmp_m.add in_srv_m, as: "in"
        cmp_m.export cmp_m.in_child.in_port
        task_m = @task_m.specialize
        in_srv =  task_m.require_dynamic_service "in", as: "in2"

        cmp = syskit_stub_and_deploy(cmp_m.use("in" => in_srv), remote_task: false)
        port_reader = cmp.in_port.writer
        syskit_configure_and_start(cmp, recursive: false)
        refute cmp.in_child.setup?
        refute port_reader.ready?

        expect_execution.scheduler(true).to do
            achieve { port_reader.ready? }
        end
    end
    it "queues a PortAccessFailure error on the port's component if creating "\
       "the port failed" do
        error = Class.new(RuntimeError)
        task = syskit_stub_deploy_and_configure(task_m)
        in_port = Orocos.allow_blocking_calls { task.orocos_task.raw_port("in") }
        flexmock(task.orocos_task).should_receive(:raw_port)
                                  .with("in").once.and_return(in_port)
        flexmock(in_port).should_receive(:writer).once.and_raise(error)
        port_writer = task.in_port.writer
        plan.unmark_mission_task(task)
        expect_execution { task.start! }.to do
            have_internal_error(
                task, Syskit::PortAccessFailure
                      .match.with_ruby_exception(error)
            )
        end

        refute port_writer.ready?
    end
    it "validates the given samples if the writer is not yet accessible" do
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer
        flexmock(Typelib).should_receive(:from_ruby).once
                         .with([], abstract_task.in_port.type)
        port_writer.write([])
    end
    it "rebinds to actual tasks that replaced the task" do
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_writer = abstract_task.in_port.writer
        task = syskit_stub_deploy_and_configure(task_m)
        plan.replace(abstract_task, task)

        syskit_wait_ready(port_writer, component: task)
        assert_equal task.in_port, port_writer.resolved_port
        assert_equal Orocos.allow_blocking_calls { task.orocos_task.port("in") },
                     port_writer.writer.port
    end

    describe "#disconnect" do
        attr_reader :task, :writer
        before do
            @task = syskit_stub_deploy_and_configure(task_m)
            @writer = task.in_port.writer
        end

        it "asynchronously disconnects a port that is ready" do
            syskit_wait_ready(writer)
            writer.disconnect
            expect_execution.to { achieve { !writer.connected? } }
        end

        it "ensures that the port will not become ready if called "\
           "before the resolution starts" do
            task = syskit_stub_deploy_and_configure(task_m)
            writer = task.in_port.writer
            flexmock(writer).should_receive(:resolve).never
            writer.disconnect
            syskit_start(task)
            execute_one_cycle
        end

        it "ensures that the port will not become ready if resolution is progressing" do
            task = syskit_stub_deploy_and_configure(task_m)
            writer = task.in_port.writer
            # Do not use syskit_start here. It would run all the event handlers,
            # which in turn would give a change for the promises to finish and
            # be processes
            #
            # #start! runs through the synchronous event processing codepath,
            # and therefore does not call any handler
            expect_execution { task.start! }.join_all_waiting_work(false).to_run
            expect_execution { writer.disconnect }.to { achieve { !writer.ready? } }
        end

        describe "automatic disconnection" do
            attr_reader :cmp, :child, :orocos_writer
            before do
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: "c"
                cmp_m.export cmp_m.c_child.in_port

                @cmp = syskit_stub_deploy_configure_and_start(cmp_m)
                @child = cmp.c_child
                @writer = w = cmp.in_port.writer
                expect_execution.to { achieve { w.ready? } }
                @orocos_writer = writer.orocos_accessor
                assert @orocos_writer.connected?
            end

            it "automatically disconnects when the port's component is finalized" do
                plan.add_permanent_task(@child)
                plan.unmark_mission_task(@cmp)

                expect_execution.garbage_collect(true).to { achieve { cmp.finalized? } }
                refute @child.finalized?
                expect_execution.to { achieve { !orocos_writer.connected? } }
            end

            it "automatically disconnects when the port's actual component "\
               "is finalized" do
                cmp.remove_child child

                expect_execution.garbage_collect(true).to { achieve { child.finalized? } }
                refute cmp.finalized?
                expect_execution.to { achieve { !orocos_writer.connected? } }
            end
        end
    end
end

describe Syskit::OutputReader do
    attr_reader :task_m
    before do
        @task_m = Syskit::TaskContext.new_submodel do
            output_port "out", "/double"
            dynamic_output_port(/out\d/, "/double")
        end
    end

    it "resolves the reader" do
        task = syskit_stub_deploy_and_configure(task_m)
        port_reader = task.out_port.reader
        syskit_wait_ready(port_reader)
        assert_equal task.out_port, port_reader.resolved_port
        assert_equal Orocos.allow_blocking_calls { task.orocos_task.port("out") },
                     port_reader.reader.port
    end
    it "waits for the underlying component to be configured if the port is dynamic" do
        out_srv_m = Syskit::DataService.new_submodel do
            output_port "out", "/double"
        end
        @task_m.class_eval do
            def configure
                super
                Orocos.allow_blocking_calls do
                    orocos_task.create_output_port "out2", "/double"
                end
            end
            dynamic_service out_srv_m, as: "out" do
                provides out_srv_m, "out" => "out2"
            end
        end

        cmp_m = Syskit::Composition.new_submodel
        cmp_m.add out_srv_m, as: "out"
        cmp_m.export cmp_m.out_child.out_port
        task_m = @task_m.specialize
        out_srv =  task_m.require_dynamic_service "out", as: "out2"

        cmp = syskit_stub_and_deploy(cmp_m.use("out" => out_srv), remote_task: false)
        port_reader = cmp.out_port.reader
        syskit_configure_and_start(cmp, recursive: false)
        refute cmp.out_child.setup?
        refute port_reader.ready?

        expect_execution.scheduler(true).to do
            achieve { port_reader.ready? }
        end
    end
    it "queues a PortAccessFailure error on the port's component "\
       "if creating the port failed" do
        error = Class.new(RuntimeError)
        task = syskit_stub_deploy_and_configure(task_m)
        out_port = Orocos.allow_blocking_calls { task.orocos_task.raw_port("out") }
        flexmock(task.orocos_task).should_receive(:raw_port)
                                  .with("out").once.and_return(out_port)
        flexmock(out_port).should_receive(:reader).once.and_raise(error)
        port_reader = task.out_port.reader

        plan.unmark_mission_task(task)
        expect_execution { task.start! }
            .to do
                have_internal_error(
                    task, Syskit::PortAccessFailure
                          .match
                          .with_ruby_exception(error)
                )
            end
        refute port_reader.ready?
    end
    it "rebinds to actual tasks that replaced the task" do
        plan.add_permanent_task(abstract_task = task_m.as_plan)
        port_reader = abstract_task.out_port.reader
        task = syskit_stub_deploy_and_configure(task_m)
        plan.replace(abstract_task, task)

        syskit_wait_ready(port_reader, component: task)
        assert_equal task.out_port, port_reader.resolved_port
        assert_equal Orocos.allow_blocking_calls { task.orocos_task.port("out") },
                     port_reader.reader.port
    end

    describe "#read_new" do
        before do
            @task = syskit_stub_deploy_and_configure(task_m, remote_task: false)
            @port_reader = @task.out_port.reader
            @orocos_port = Orocos.allow_blocking_calls do
                @task.orocos_task.raw_port("out")
            end
        end
        it "returns nil if the reader is not yet connected" do
            refute @port_reader.connected?
            assert_nil @port_reader.read_new
        end
        describe "without an explicitely-provided sample" do
            before do
                syskit_wait_ready(@port_reader)
            end
            it "reads new samples" do
                @orocos_port.write(10)
                assert_equal 10, @port_reader.read_new
            end
            it "returns nil if there are no samples" do
                assert_nil @port_reader.read_new
            end
            it "returns nil if there are no new samples" do
                @orocos_port.write(10)
                @port_reader.read_new
                assert_nil @port_reader.read_new
            end
        end
        describe "with an explicitely-provided sample" do
            before do
                syskit_wait_ready(@port_reader)
                @sample = Typelib.from_ruby(0, @task.out_port.type)
            end
            it "reads new samples" do
                @orocos_port.write(10)
                assert_equal 10, @port_reader.read_new(@sample)
                assert_equal 10, @sample.to_ruby
            end
            it "returns nil if there are no samples" do
                assert_nil @port_reader.read_new(@sample)
                assert_equal 0, @sample.to_ruby
            end
            it "returns nil if there are no new samples" do
                @orocos_port.write(10)
                @port_reader.read_new(@sample)
                assert_nil @port_reader.read_new(@sample)
                assert_equal 10, @sample.to_ruby
            end
        end
    end

    describe "#read" do
        before do
            @task = syskit_stub_deploy_and_configure(task_m, remote_task: false)
            @port_reader = @task.out_port.reader
            @orocos_port = Orocos.allow_blocking_calls do
                @task.orocos_task.raw_port("out")
            end
        end
        it "returns nil if the reader is not yet connected" do
            refute @port_reader.connected?
            assert_nil @port_reader.read
        end
        describe "without an explicitely-provided sample" do
            before do
                syskit_wait_ready(@port_reader)
            end
            it "reads new samples" do
                @orocos_port.write(10)
                assert_equal 10, @port_reader.read
            end
            it "returns nil if there are no samples" do
                assert_nil @port_reader.read
            end
            it "returns the last received sample if there are no new samples" do
                @orocos_port.write(10)
                @port_reader.read
                assert_equal 10, @port_reader.read
            end
        end
        describe "with an explicitely-provided sample" do
            before do
                syskit_wait_ready(@port_reader)
                @sample = Typelib.from_ruby(0, @task.out_port.type)
            end
            it "reads new samples" do
                @orocos_port.write(10)
                assert_equal 10, @port_reader.read(@sample)
                assert_equal 10, @sample.to_ruby
            end
            it "returns nil if there are no samples" do
                assert_nil @port_reader.read(@sample)
                assert_equal 0, @sample.to_ruby
            end
            it "returns the last received sample if there are no new samples" do
                @orocos_port.write(10)
                @port_reader.read
                assert_equal 10, @port_reader.read(@sample)
                assert_equal 10, @sample.to_ruby
            end
        end
    end

    describe "#clear" do
        before do
            @task = syskit_stub_deploy_and_configure(task_m, remote_task: false)
            @port_reader = @task.out_port.reader
            @orocos_port = Orocos.allow_blocking_calls do
                @task.orocos_task.raw_port("out")
            end
        end
        it "does nothing if the port is not yet connected" do
            refute @port_reader.connected?
            @port_reader.clear
        end
        it "removes any newly received sample" do
            syskit_wait_ready(@port_reader)
            @orocos_port.write(10)
            @port_reader.clear
            assert_nil @port_reader.read
        end
        it "removes any already-read sample" do
            syskit_wait_ready(@port_reader)
            @orocos_port.write(10)
            @port_reader.read
            @port_reader.clear
            assert_nil @port_reader.read
        end
    end

    describe "#disconnect" do
        attr_reader :task, :reader
        before do
            @task = syskit_stub_deploy_and_configure(task_m)
            @reader = task.out_port.reader
        end

        it "asynchronously disconnects a port that is ready" do
            syskit_wait_ready(reader)
            reader.disconnect
            expect_execution.to { achieve { !reader.connected? } }
        end

        it "ensures that the port will not become ready if called before the "\
           "resolution starts" do
            task = syskit_stub_deploy_and_configure(task_m)
            reader = task.out_port.reader
            flexmock(reader).should_receive(:resolve).never
            reader.disconnect
            syskit_start(task)
        end

        it "ensures that the port will not become ready if resolution is progressing" do
            task = syskit_stub_deploy_and_configure(task_m)
            reader = task.out_port.reader
            # Do not use syskit_start here. It would run all the event handlers,
            # which in turn would give a change for the promises to finish and
            # be processes
            #
            # #start! runs through the synchronous event processing codepath,
            # and therefore does not call any handler
            expect_execution { task.start! }.join_all_waiting_work(false).to_run
            expect_execution { reader.disconnect }
                .to { achieve { !reader.ready? } }
        end

        describe "automatic disconnection" do
            attr_reader :cmp, :child, :orocos_reader
            before do
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: "c"
                cmp_m.export cmp_m.c_child.out_port

                @cmp = syskit_stub_deploy_configure_and_start(cmp_m)
                @child = cmp.c_child
                @reader = r = cmp.out_port.reader
                expect_execution.to { achieve { r.ready? } }
                @orocos_reader = reader.orocos_accessor
                assert @orocos_reader.connected?
            end

            it "automatically disconnects when the port's component is finalized" do
                plan.add_permanent_task(@child)
                plan.unmark_mission_task(@cmp)

                expect_execution.garbage_collect(true).to { achieve { cmp.finalized? } }
                refute @child.finalized?
                expect_execution.to { achieve { !orocos_reader.connected? } }
            end

            it "automatically disconnects when the port's actual component "\
               "is finalized" do
                cmp.remove_child child

                expect_execution.garbage_collect(true).to { achieve { child.finalized? } }
                refute cmp.finalized?
                expect_execution.to { achieve { !orocos_reader.connected? } }
            end
        end
    end
end
