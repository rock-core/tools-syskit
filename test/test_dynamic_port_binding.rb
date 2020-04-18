# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe DynamicPortBinding do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
        end

        describe "on creation" do
            before do
                @matcher = @task_m.match.out_port
                @port_binding_m =
                    Models::DynamicPortBinding
                    .create_from_matcher(@matcher)
            end

            it "is not attached nor valid on creation" do
                m = @port_binding_m.instanciate
                refute m.attached?
                refute m.valid?
            end

            it "is attached but not valid once attach_to_task has been called" do
                m = @port_binding_m.instanciate
                @task = syskit_stub_and_deploy(@task_m)
                m.attach_to_task(@task)
                assert m.attached?
                refute m.valid?
            end

            describe "from a port matcher" do
                before do
                    @port_binding =
                        Models::DynamicPortBinding
                        .create_from_matcher(@task_m.match.running.out_port)
                        .instanciate
                end

                it "reports the port type" do
                    assert_equal @task_m.out_port.type, @port_binding.type
                end

                it "reports the port's output direction" do
                    assert @port_binding.output?
                end

                it "reports the port's input direction" do
                    port_binding =
                        Models::DynamicPortBinding
                        .create_from_matcher(@task_m.match.running.in_port)
                        .instanciate
                    refute port_binding.output?
                end
            end

            describe "from a component port" do
                before do
                    @port_binding =
                        Models::DynamicPortBinding
                        .create_from_component_port(@task_m.out_port)
                        .instanciate
                end

                it "reports the port type" do
                    assert_equal @task_m.out_port.type, @port_binding.type
                end

                it "reports the port's output direction" do
                    assert @port_binding.output?
                end

                it "reports the port's input direction" do
                    port_binding =
                        Models::DynamicPortBinding
                        .create_from_component_port(@task_m.in_port)
                        .instanciate
                    refute port_binding.output?
                end
            end

            describe "from a data service port" do
                before do
                    @srv_m = Syskit::DataService.new_submodel do
                        input_port "srv_in", "/double"
                        output_port "srv_out", "/double"
                    end
                    @cmp_m = Syskit::Composition.new_submodel
                    @cmp_m.add @srv_m, as: "test"
                    @port_binding =
                        Models::DynamicPortBinding
                        .create_from_component_port(@cmp_m.test_child.srv_out_port)
                        .instanciate
                end

                it "reports the port type" do
                    assert_equal @srv_m.srv_out_port.type, @port_binding.type
                end

                it "reports the port's output direction" do
                    assert @port_binding.output?
                end

                it "reports the port's input direction" do
                    port_binding =
                        Models::DynamicPortBinding
                        .create_from_component_port(@cmp_m.test_child.srv_in_port)
                        .instanciate
                    refute port_binding.output?
                end
            end
        end

        describe "#to_data_accessor" do
            it "creates an OutputReader for an output port" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.out_port)
                    .instanciate

                reader = port_binding.to_data_accessor

                assert_kind_of DynamicPortBinding::OutputReader, reader
                assert_equal port_binding, reader.port_binding
            end

            it "passes the policy to the reader" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.out_port)
                    .instanciate

                reader = port_binding.to_data_accessor(type: :buffer, size: 20)
                assert_equal({ type: :buffer, size: 20 }, reader.policy)
            end

            it "creates an InputWriter for an input port" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.in_port)
                    .instanciate

                writer = port_binding.to_data_accessor

                assert_kind_of DynamicPortBinding::InputWriter, writer
                assert_equal port_binding, writer.port_binding
            end

            it "passes the policy to the writer" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.in_port)
                    .instanciate

                writer = port_binding.to_data_accessor(type: :buffer, size: 20)
                assert_equal({ type: :buffer, size: 20 }, writer.policy)
            end
        end

        describe "#to_bound_data_accessor" do
            before do
                @task = syskit_stub_deploy_and_configure(@task_m)
            end

            it "creates a BoundOutputReader for an output port" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.out_port)
                    .instanciate

                reader = port_binding.to_bound_data_accessor("test", @task)

                assert_kind_of DynamicPortBinding::BoundOutputReader, reader
                assert_equal port_binding, reader.port_binding
                assert_equal "test", reader.name
                assert_equal @task, reader.component
            end

            it "passes the policy to the reader" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.out_port)
                    .instanciate

                reader = port_binding.to_bound_data_accessor(
                    "test", @task, type: :buffer, size: 20
                )
                assert_equal({ type: :buffer, size: 20 }, reader.policy)
            end

            it "creates a BoundInputWriter for an input port" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.in_port)
                    .instanciate

                writer = port_binding.to_bound_data_accessor("test", @task)

                assert_kind_of DynamicPortBinding::BoundInputWriter, writer
                assert_equal port_binding, writer.port_binding
                assert_equal "test", writer.name
                assert_equal @task, writer.component
            end

            it "passes the policy to the writer" do
                port_binding =
                    Models::DynamicPortBinding
                    .create_from_component_port(@task_m.in_port)
                    .instanciate

                writer = port_binding.to_bound_data_accessor(
                    "test", @task, type: :buffer, size: 20
                )
                assert_equal({ type: :buffer, size: 20 }, writer.policy)
            end
        end

        describe "#update from a port matcher" do
            attr_reader :task, :port_binding

            before do
                @port_binding_m =
                    Models::DynamicPortBinding
                    .create_from_matcher(@task_m.match.running.out_port)
                @task = syskit_stub_and_deploy(@task_m, remote_task: false)
                @port_binding = @port_binding_m.instanciate.attach_to_task(@task)
            end

            it "returns [false, nil] in #update if the binding is not attached" do
                port_binding = @port_binding_m.instanciate
                assert_equal [false, nil], port_binding.update
            end

            it "returns [false, nil] if there are no matches in the plan" do
                assert_equal [false, nil], @port_binding.update
            end

            it "returns [true, port] if there is a new match in the plan" do
                syskit_configure_and_start(@task)

                assert_equal [true, @task.out_port], @port_binding.update
                assert @port_binding.valid?
            end

            it "returns [false, port] if the current match is still valid" do
                syskit_configure_and_start(@task)
                @port_binding.update
                assert_equal [false, @task.out_port], @port_binding.update
                assert @port_binding.valid?
            end

            it "returns [true, nil] if the current match is not valid anymore" do
                syskit_configure_and_start(@task)
                @port_binding.update
                syskit_stop task

                assert_equal [true, nil], @port_binding.update
                refute @port_binding.valid?
            end
        end

        describe "#update from component port" do
            attr_reader :cmp, :ds

            before do
                task_m = Syskit::TaskContext.new_submodel do
                    output_port "out", "/double"
                end
                @cmp_m = Syskit::Composition.new_submodel do
                    add task_m, as: "test"
                end

                @cmp = syskit_stub_and_deploy(@cmp_m, remote_task: false)
                @port_binding_m = Models::DynamicPortBinding.create_from_component_port(
                    @cmp_m.test_child.out_port
                )
                @port_binding = @port_binding_m.instanciate.attach_to_task(@cmp)
                @expected_port = @cmp_m.test_child.out_port.bind(@cmp.test_child)
            end

            it "returns [true, port] the first time if the underlying component "\
               "is not finalized" do
                assert_equal [true, @expected_port], @port_binding.update
            end

            it "returns [false, port] the second time if the underlying component "\
               "is still not finalized" do
                @port_binding.update
                assert_equal [false, @expected_port], @port_binding.update
            end

            it "returns [false, ni] the first time if the underlying component "\
               "is already finalized" do
                expect_execution { plan.unmark_mission_task(@cmp) }
                    .garbage_collect(true)
                    .to_run
                assert_equal [false, nil], @port_binding.update
            end

            it "returns [false, ni] after a successful update if the underlying "\
               "component is finalized" do
                @port_binding.update
                expect_execution { plan.unmark_mission_task(@cmp) }
                    .garbage_collect(true)
                    .to_run
                assert_equal [true, nil], @port_binding.update
                assert_equal [false, nil], @port_binding.update
            end
        end

        describe "#update from a data service port" do
            attr_reader :cmp, :ds

            before do
                srv_m = Syskit::DataService.new_submodel do
                    output_port "srv_out", "/double"
                end
                task_m = Syskit::TaskContext.new_submodel do
                    output_port "out", "/double"
                end
                task_m.provides srv_m, as: "test"
                @cmp_m = Syskit::Composition.new_submodel do
                    add srv_m, as: "test"
                end

                @cmp = syskit_stub_and_deploy(
                    @cmp_m.use("test" => task_m),
                    remote_task: false
                )
                @port_binding_m =
                    Models::DynamicPortBinding
                    .create_from_component_port(@cmp_m.test_child.srv_out_port)
                @port_binding = @port_binding_m.instanciate.attach_to_task(@cmp)
            end

            it "returns [true, port] the first time if the underlying component "\
               "is not finalized" do
                updated, port = @port_binding.update
                assert updated
                assert_equal "srv_out", port.name
                assert_equal @cmp.test_child.out_port, port.to_component_port
            end

            it "returns [false, port] the second time if the underlying component "\
               "is still not finalized" do
                @port_binding.update
                updated, port = @port_binding.update
                refute updated
                assert_equal "srv_out", port.name
                assert_equal @cmp.test_child.out_port, port.to_component_port
            end

            it "returns [false, ni] the first time if the underlying component "\
               "is already finalized" do
                expect_execution { plan.unmark_mission_task(@cmp) }
                    .garbage_collect(true)
                    .to_run
                assert_equal [false, nil], @port_binding.update
            end

            it "returns [false, ni] after a successful update if the underlying "\
               "component is finalized" do
                @port_binding.update
                expect_execution { plan.unmark_mission_task(@cmp) }
                    .garbage_collect(true)
                    .to_run
                assert_equal [true, nil], @port_binding.update
                assert_equal [false, nil], @port_binding.update
            end
        end
    end

    describe DynamicPortBinding::Accessor do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            @task = syskit_stub_deploy_configure_and_start(@task_m)
        end

        describe "#update" do
            attr_reader :task, :port_binding

            before do
                @port_binding = flexmock
                @accessor = DynamicPortBinding::Accessor.new(@port_binding)
                flexmock(@accessor)
                    .should_receive(:create_accessor)
                    .explicitly
                    .with(@task.out_port).and_return { @task.out_port.reader }
            end

            it "not valid nor connected on creation" do
                refute @accessor.valid?
                refute @accessor.connected?
            end

            it "returns false if the port matcher does not match" do
                @port_binding.should_receive(:update).and_return([false, nil])
                refute @accessor.update
                refute @accessor.valid?
                refute @accessor.connected?
            end

            it "returns true and creates an accessor to the found port if the port "\
               "matcher found something" do
                @port_binding.should_receive(:update).and_return([true, @task.out_port])
                assert @accessor.update
                assert_equal @task.out_port, @accessor.resolved_accessor.port
                assert @accessor.valid?
                wait_until_connected @accessor
            end

            it "keeps the current reader if the matcher finds the same port" do
                @port_binding.should_receive(:update)
                             .and_return([true, @task.out_port])
                             .and_return([false, @task.out_port])

                @accessor.update
                real_accessor = @accessor.resolved_accessor
                assert @accessor.update
                assert_same real_accessor, @accessor.resolved_accessor
            end

            it "disconnects the current accessor if the current port is not matching "\
               "anymore" do
                @port_binding.should_receive(:update)
                             .and_return([true, @task.out_port])
                             .and_return([true, nil])

                @accessor.update
                real_accessor = @accessor.resolved_accessor
                wait_until_connected @accessor

                flexmock(real_accessor).should_receive(:disconnect).once.pass_thru

                assert @accessor.update
                assert_nil @accessor.resolved_accessor
                refute @accessor.valid?
                refute @accessor.connected?
            end

            it "changes the read port if the match changes" do
                other_task = syskit_stub_deploy_configure_and_start(@task_m)
                @accessor.should_receive(:create_accessor).explicitly
                         .with(other_task.out_port)
                         .and_return { other_task.out_port.reader }
                @port_binding.should_receive(:update)
                             .and_return([true, @task.out_port])
                             .and_return([true, other_task.out_port])

                @accessor.update
                real_accessor = @accessor.resolved_accessor
                wait_until_connected @accessor

                flexmock(real_accessor).should_receive(:disconnect).once.pass_thru

                assert @accessor.update
                refute_same real_accessor, @accessor.resolved_accessor
                assert_equal other_task.out_port, @accessor.resolved_accessor.port
                refute @accessor.connected?
                assert @accessor.valid?
                wait_until_connected @accessor
            end
        end

        describe "#disconnect" do
            before do
                @port_binding = Models::DynamicPortBinding
                                .create_from_matcher(@task_m.match.out_port)
                                .instanciate.attach_to_task(@task)

                @accessor = DynamicPortBinding::Accessor.new(@port_binding)
                flexmock(@accessor)
                    .should_receive(:create_accessor)
                    .explicitly
                    .with(@task.out_port).and_return { @task.out_port.reader }
            end

            it "disconnects the current reader" do
                @accessor.update
                flexmock(@accessor.resolved_accessor)
                    .should_receive(:disconnect).once.pass_thru
                flexmock(@port_binding).should_receive(:reset).once
                @accessor.disconnect
                refute @accessor.valid?
                refute @accessor.connected?
            end

            it "resets the port binding so that it would re-bind to the same port" do
                @accessor.update
                @accessor.disconnect
                assert @accessor.update
                assert_equal @task.out_port, @accessor.resolved_accessor.port
            end
        end

        def wait_until_connected(accessor)
            expect_execution.to { achieve { accessor.connected? } }
        end
    end

    describe DynamicPortBinding::OutputReader do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
        end

        it "creates the reader with the given policy" do
            reader = Models::DynamicPortBinding
                     .create(@task_m.out_port)
                     .instanciate
                     .to_data_accessor(type: :buffer, size: 20)
            task = syskit_stub_deploy_and_configure(@task_m)
            reader.attach_to_task(task)
            reader.update

            assert_equal({ type: :buffer, size: 20 }, reader.resolved_accessor.policy)
        end

        describe "#read_new" do
            before do
                @port_resolver = flexmock
                port_binding_m = Models::DynamicPortBinding.new(
                    flexmock, flexmock,
                    output: true, port_resolver: flexmock(instanciate: @port_resolver)
                )
                @value_resolver = flexmock
                @value_resolver.should_receive(:__resolve).and_return { |v| v }.by_default

                @port_binding = DynamicPortBinding.new(port_binding_m)
                @reader = DynamicPortBinding::OutputReader.new(
                    @port_binding, value_resolver: @value_resolver
                )

                @task = syskit_stub_deploy_configure_and_start(
                    @task_m, remote_task: false
                )

                flexmock(@port_binding)
                    .should_receive(:update)
                    .and_return([true, @task.out_port]).by_default
            end

            it "returns nil if the accessor is not attached" do
                assert_nil @reader.read_new
            end

            it "returns nil if there are no samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                assert_nil @reader.read_new
            end

            it "returns nil if there are only already read samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                assert_nil @reader.read_new
                execute { syskit_write @task.out_port, 2 }
                @reader.read_new
                assert_nil @reader.read_new
            end

            it "returns new samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                execute { syskit_write @task.out_port, 2 }
                assert_equal 2, @reader.read_new
            end

            it "processes the samples through the given value resolver" do
                @value_resolver.should_receive(:__resolve).with(2).and_return(42)
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                execute { syskit_write @task.out_port, 2 }
                assert_equal 42, @reader.read_new
            end

            def wait_until_connected(source)
                assert source.update,
                       "#{source} cannot be connected, no port to attach to"
                expect_execution.to { achieve { source.connected? } }
            end
        end

        describe "#read" do
            before do
                @port_resolver = flexmock
                port_binding_m = Models::DynamicPortBinding.new(
                    flexmock, flexmock,
                    output: true, port_resolver: flexmock(instanciate: @port_resolver)
                )
                @value_resolver = flexmock
                @value_resolver.should_receive(:__resolve).and_return { |v| v }.by_default

                @port_binding = DynamicPortBinding.new(port_binding_m)
                @reader = DynamicPortBinding::OutputReader.new(
                    @port_binding, value_resolver: @value_resolver
                )

                @task = syskit_stub_deploy_configure_and_start(
                    @task_m, remote_task: false
                )

                flexmock(@port_binding)
                    .should_receive(:update)
                    .and_return([true, @task.out_port]).by_default
            end

            it "returns nil if the accessor is not attached" do
                assert_nil @reader.read
            end

            it "returns nil if there are no samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                assert_nil @reader.read
            end

            it "returns already read samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                assert_nil @reader.read
                execute { syskit_write @task.out_port, 2 }
                assert_equal 2, @reader.read
                assert_equal 2, @reader.read
            end

            it "returns new samples" do
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                execute { syskit_write @task.out_port, 2 }
                assert_equal 2, @reader.read
            end

            it "processes the samples through the given value resolver" do
                @value_resolver.should_receive(:__resolve).with(2.0).and_return(42)
                @reader.attach_to_task(@task)
                wait_until_connected @reader
                execute { syskit_write @task.out_port, 2 }
                assert_equal 42, @reader.read
            end
        end

        def wait_until_connected(source)
            assert source.update,
                   "#{source} cannot be connected, no port to attach to"
            expect_execution.to { achieve { source.connected? } }
        end
    end

    describe DynamicPortBinding::BoundOutputReader do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
        end

        it "attaches to the bound component" do
            task = syskit_stub_deploy_and_configure(@task_m)

            reader =
                Models::DynamicPortBinding
                .create_from_component_port(@task_m.out_port)
                .instanciate
                .to_bound_data_accessor("test", task)

            reader.attach
            reader.update
            assert_equal task.out_port, reader.resolved_accessor.port
        end
    end

    describe DynamicPortBinding::InputWriter do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
            end
        end

        it "creates the writer with the given policy" do
            writer = Models::DynamicPortBinding
                     .create(@task_m.in_port)
                     .instanciate
                     .to_data_accessor(type: :buffer, size: 20)
            task = syskit_stub_deploy_and_configure(@task_m)
            writer.attach_to_task(task)
            writer.update

            assert_equal({ type: :buffer, size: 20 }, writer.resolved_accessor.policy)
        end

        describe "#write" do
            attr_reader :task, :writer

            before do
                @port_resolver = flexmock
                port_binding_m = Models::DynamicPortBinding.new(
                    flexmock, flexmock,
                    output: false, port_resolver: flexmock(instanciate: @port_resolver)
                )

                @port_binding = DynamicPortBinding.new(port_binding_m)
                @writer = DynamicPortBinding::InputWriter.new(@port_binding)

                @task = syskit_stub_deploy_configure_and_start(
                    @task_m, remote_task: false
                )

                flexmock(@port_binding)
                    .should_receive(:update)
                    .and_return([true, @task.in_port]).by_default
            end

            it "writes to the underlying port" do
                assert @writer.update
                expect_execution.to { achieve { writer.connected? } }

                sample = expect_execution { syskit_write @writer, 42 }
                         .to { have_one_new_sample task.in_port }
                assert_equal 42, sample
            end
        end

        def wait_until_connected(source)
            assert source.update,
                   "#{source} cannot be connected, no port to attach to"
            expect_execution.to { achieve { source.connected? } }
        end
    end

    describe DynamicPortBinding::BoundInputWriter do
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
            end
        end

        it "attaches to the bound component" do
            task = syskit_stub_deploy_and_configure(@task_m)

            reader =
                Models::DynamicPortBinding
                .create_from_component_port(@task_m.in_port)
                .instanciate
                .to_bound_data_accessor("test", task)

            reader.attach
            reader.update
            assert_equal task.in_port, reader.resolved_accessor.port
        end
    end
end
