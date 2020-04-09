# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Coordination::TaskScriptExtension do
    it "sets the CompositionChild instance as model for child tasks" do
        data_service = Syskit::DataService.new_submodel { output_port "out", "/double" }
        composition_m = Syskit::Composition.new_submodel do
            add data_service, as: "test"
        end
        assert_equal composition_m.test_child, composition_m.script.test_child.model.model
    end

    describe "model-level scripts" do
        attr_reader :base_srv_m, :srv_m, :component_m, :composition_m
        before do
            @base_srv_m = Syskit::DataService.new_submodel do
                input_port "base_in", "/double"
                output_port "base_out", "/double"
            end
            @srv_m = Syskit::DataService.new_submodel do
                input_port "srv_in", "/double"
                output_port "srv_out", "/double"
            end
            srv_m.provides base_srv_m, "base_in" => "srv_in", "base_out" => "srv_out"
            @component_m = syskit_stub_task_context_model "Task" do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            component_m.provides srv_m, as: "test"
            @composition_m = Syskit::Composition.new_submodel
            composition_m.add base_srv_m, as: "test"
        end

        describe "mapping ports from services using submodel creation" do
            def start
                component = syskit_stub_deploy_and_configure(component_m)
                composition_m = self.composition_m.new_submodel
                composition_m.overload "test", component_m
                composition = syskit_stub_deploy_configure_and_start(composition_m.use("test" => component))
                [composition, component]
            end

            it "gives writer access to input ports mapped from services" do
                writer = nil
                composition_m.script do
                    writer = test_child.base_in_port.writer
                    begin
                        test_child.base_in_port.to_component_port
                    rescue StandardError
                    end
                end
                composition, component = start
                writer.write(10)
                assert_equal 10, composition.test_child.orocos_task.local_ruby_task.in.read
            end

            it "gives reader access to input ports mapped from services" do
                reader = nil
                composition_m.script do
                    reader = test_child.base_out_port.reader
                end
                composition, component = start
                composition.test_child.orocos_task.local_ruby_task.out.write(10)
                assert_equal 10, reader.read
            end
        end

        describe "mapping ports from services using dependency injection" do
            def start
                component = syskit_stub_deploy_and_configure(component_m)
                composition = syskit_stub_deploy_configure_and_start(composition_m.use("test" => component))
                [composition, component]
            end

            it "gives writer access to input ports mapped from services" do
                writer = nil
                composition_m.script do
                    writer = test_child.base_in_port.writer
                end
                composition, component = start
                writer.write(10)
                assert_equal 10, composition.test_child.orocos_task.local_ruby_task.in.read
            end

            it "gives reader access to input ports mapped from services" do
                reader = nil
                composition_m.script do
                    reader = test_child.base_out_port.reader
                end
                composition, component = start
                composition.test_child.orocos_task.local_ruby_task.out.write(10)
                assert_equal 10, reader.read
            end
        end

        it "gives writer access to input ports" do
            writer = nil
            component_m.script do
                writer = in_port.writer
            end
            component = syskit_stub_deploy_and_configure(component_m)
            syskit_start(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.local_ruby_task.in.read
        end

        it "gives access to output ports" do
            reader = nil
            component_m.script do
                reader = out_port.reader
            end
            component = syskit_stub_deploy_and_configure(component_m)
            syskit_start(component)
            component.orocos_task.local_ruby_task.out.write(10)
            assert_equal 10, reader.read
        end
    end

    describe "input port access" do
        attr_reader :component, :srv_m, :task_m

        before do
            @srv_m = srv_m = Syskit::DataService.new_submodel { input_port "srv_in", "/double" }
            @task_m = Syskit::TaskContext.new_submodel(name: "Task") do
                input_port "in", "/double"
            end
            task_m.provides srv_m, as: "test"
            @component = syskit_stub_deploy_and_configure task_m
        end

        it "returns input port instances" do
            port = component.script.in_port
            assert_kind_of Syskit::InputPort, port
        end

        it "gives access to input ports when created at the instance level" do
            writer = nil
            component.script do
                writer = in_port.writer
            end

            syskit_start(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.local_ruby_task.in.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, as: "test"
            assert_kind_of Syskit::InputPort, composition_m.script.test_child.srv_in_port
        end

        it "gives access to ports from grandchildren" do
            root_m = Syskit::Composition.new_submodel(name: "Root") { attr_reader :writer }
            child_m = Syskit::Composition.new_submodel(name: "Child")
            child_m.add task_m, as: "test"
            root_m.add child_m, as: "test"

            root_m.script do
                writer = test_child.test_child.in_port.writer
                wait_until_ready writer
                execute do
                    @writer = writer
                    writer.write 10
                end
            end

            root = syskit_stub_deploy_configure_and_start(root_m)
            writer = expect_execution.to { achieve { root.writer } }
            assert_equal root.test_child.test_child, writer.port.component
            assert_equal "in", writer.port.name
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, as: "test"
            composition = syskit_stub_and_deploy(composition_m.use("test" => component))

            writer = nil
            composition.script do
                writer = test_child.srv_in_port.writer
            end

            syskit_configure_and_start(composition)
            syskit_configure_and_start(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.local_ruby_task.in.read
        end

        it "generates an error if trying to access a non-existent port" do
            begin
                component.script do
                    non_existent_port
                end
                flunk("out_port did not raise NoMethodError")
            rescue NoMethodError => e
                assert_equal :non_existent_port, e.name
            end
        end

        describe "writer disconnection at task stop" do
            attr_reader :writer, :actual_writer, :cmp
            before do
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: "test"
                writer = nil
                cmp_m.script do
                    writer = test_child.in_port.writer
                end
                @cmp = syskit_stub_deploy_configure_and_start(cmp_m)
                syskit_wait_ready(writer)
                @writer = writer
                @actual_writer = writer.writer
                plan.unmark_mission_task(cmp)
            end

            it "asynchronously disconnects a writer on the script's task shutdown" do
                expect_execution { cmp.stop! }.to do
                    emit cmp.stop_event
                    achieve { !actual_writer.connected? }
                    achieve { !writer.connected? }
                end
            end

            it "gobbles ComError exceptions" do
                flexmock(actual_writer).should_receive(:disconnect).and_raise(Orocos::ComError)
                expect_execution { cmp.stop! }.to do
                    emit cmp.stop_event
                    achieve { !writer.connected? }
                end
            end

            it "forwards arbitrary exceptions" do
                error = Class.new(RuntimeError)
                flexmock(actual_writer).should_receive(:disconnect).and_raise(error)
                expect_execution { cmp.stop! }
                    .to { have_framework_error_matching error }
            end
        end
    end

    describe "output port access" do
        attr_reader :component, :srv_m, :task_m

        before do
            @srv_m = Syskit::DataService.new_submodel { output_port "srv_out", "/double" }
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            task_m.provides srv_m, as: "test"
            @component = syskit_stub_deploy_and_configure task_m
        end

        it "returns output port instances" do
            port = component.script.out_port
            assert_kind_of Syskit::OutputPort, port
        end

        describe "reader disconnection at task stop" do
            attr_reader :reader, :actual_reader, :cmp
            before do
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: "test"
                reader = nil
                cmp_m.script do
                    reader = test_child.out_port.reader
                end
                @cmp = syskit_stub_deploy_configure_and_start(cmp_m)
                syskit_wait_ready(reader)
                @reader = reader
                @actual_reader = reader.reader
                plan.unmark_mission_task(cmp)
            end

            it "asynchronously disconnects a reader on the script's task shutdown" do
                expect_execution { cmp.stop! }.to do
                    emit cmp.stop_event
                    achieve { !reader.connected? }
                    achieve { !actual_reader.connected? }
                end
            end

            it "gobbles ComError exceptions" do
                flexmock(reader.reader).should_receive(:disconnect).and_raise(Orocos::ComError)
                expect_execution { cmp.stop! }.to do
                    emit cmp.stop_event
                    achieve { !reader.connected? }
                end
            end

            it "forwards arbitrary exceptions" do
                error = Class.new(RuntimeError)
                flexmock(actual_reader).should_receive(:disconnect).and_raise(error)
                expect_execution { cmp.stop! }
                    .to { have_framework_error_matching error }
            end
        end

        it "gives access to output ports" do
            reader = nil
            component.script do
                reader = out_port.reader
            end

            syskit_start(component)
            component.orocos_task.local_ruby_task.out.write(10)
            assert_equal 10, reader.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, as: "test"
            assert_kind_of Syskit::OutputPort, composition_m.script.test_child.srv_out_port
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, as: "test"
            composition = syskit_deploy_and_configure(composition_m.use("test" => component))

            reader = nil
            composition.script do
                reader = test_child.srv_out_port.reader
            end

            syskit_start(composition)
            component.orocos_task.local_ruby_task.out.write(10)
            assert_equal 10, reader.read
        end

        it "generates an error if trying to access a non-existent port" do
            begin
                component.script do
                    non_existent_port
                end
                flunk("out_port did not raise NoMethodError")
            rescue NoMethodError => e
                assert_equal :non_existent_port, e.name
            end
        end
    end
end
