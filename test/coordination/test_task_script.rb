require 'syskit/test'

describe Syskit::Coordination::TaskScriptExtension do
    include Syskit::SelfTest

    it "sets the CompositionChild instance as model for child tasks" do
        data_service = Syskit::DataService.new_submodel { output_port 'out', '/double' }
        composition_m = Syskit::Composition.new_submodel do
            add data_service, :as => 'test'
        end
        assert_equal composition_m.test_child, composition_m.script.test_child.model.model
    end

    describe "input port access" do
        attr_reader :component, :srv_m

        before do
            @srv_m = srv_m = Syskit::DataService.new_submodel { input_port 'srv_in', '/double' }
            @component = stub_deployed_task do
                input_port 'in', '/double'
                provides srv_m, :as => 'test'
            end
        end

        it "returns input port instances" do
            port = component.script.in_port
            assert_kind_of Syskit::InputPort, port
        end

        it "gives access to input ports" do
            writer = nil
            component.script do
                writer = in_port.writer
            end

            start_task_context(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.in.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            assert_kind_of Syskit::InputPort, composition_m.script.test_child.srv_in_port
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            composition = composition_m.use('test' => component).instanciate(plan)

            writer = nil
            composition.script do
                writer = test_child.srv_in_port.writer
            end

            start_task_context(composition)
            start_task_context(component)
            writer.write(10)
            assert_equal 10, component.orocos_task.in.read
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

    describe "output port access" do
        attr_reader :component, :srv_m

        before do
            @srv_m = srv_m = Syskit::DataService.new_submodel { output_port 'srv_out', '/double' }
            @component = stub_deployed_task do
                output_port 'out', '/double'
                provides srv_m, :as => 'test'
            end
        end

        it "returns output port instances" do
            port = component.script.out_port
            assert_kind_of Syskit::OutputPort, port
        end

        it "gives access to output ports" do
            reader = nil
            component.script do
                reader = out_port.reader
            end

            start_task_context(component)
            component.orocos_task.out.write(10)
            assert_equal 10, reader.read
        end

        it "gives access to ports from children" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            assert_kind_of Syskit::OutputPort, composition_m.script.test_child.srv_out_port
        end

        it "does port mapping if necessary" do
            composition_m = Syskit::Composition.new_submodel
            composition_m.add srv_m, :as => 'test'
            composition = composition_m.use('test' => component).instanciate(plan)

            reader = nil
            composition.script do
                reader = test_child.srv_out_port.reader
            end

            start_task_context(composition)
            start_task_context(component)
            component.orocos_task.out.write(10)
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

