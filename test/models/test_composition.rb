require 'syskit'
require 'syskit/test'
require './test/fixtures/simple_composition_model'

# Module used when we want to do some "public" models
module DefinitionModule
end

describe Syskit::Models::Composition do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    def models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    before do
        create_simple_composition_model
    end

    after do
        begin DefinitionModule.send(:remove_const, :Cmp)
        rescue NameError
        end
    end

    it "has a proper name if assigned to a constant" do
        model = Syskit::Composition.new_submodel
        DefinitionModule.const_set :Cmp, model
        assert_equal "DefinitionModule::Cmp", model.name
    end
    
    describe "#new_submodel" do
        it "registers the submodel" do
            submodel = Syskit::Composition.new_submodel
            subsubmodel = submodel.new_submodel

            assert Syskit::Component.submodels.include?(submodel)
            assert Syskit::Component.submodels.include?(subsubmodel)
            assert Syskit::Composition.submodels.include?(submodel)
            assert Syskit::Composition.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end

        it "does not register the submodels on provided services" do
            submodel = Syskit::Composition.new_submodel
            ds = Syskit::DataService.new_submodel
            submodel.provides ds, :as => 'srv'
            subsubmodel = submodel.new_submodel

            assert !ds.submodels.include?(subsubmodel)
            assert submodel.submodels.include?(subsubmodel)
        end
    end

    describe "#clear_submodels" do
        it "removes registered submodels" do
            m1 = Syskit::Composition.new_submodel
            m2 = Syskit::Composition.new_submodel
            m11 = m1.new_submodel

            m1.clear_submodels
            assert !m1.submodels.include?(m11)
            assert Syskit::Component.submodels.include?(m1)
            assert Syskit::Composition.submodels.include?(m1)
            assert Syskit::Component.submodels.include?(m2)
            assert Syskit::Composition.submodels.include?(m2)
            assert !Syskit::Component.submodels.include?(m11)
            assert !Syskit::Composition.submodels.include?(m11)

            m11 = m1.new_submodel
            Syskit::Composition.clear_submodels
            assert !m1.submodels.include?(m11)
            assert !Syskit::Component.submodels.include?(m1)
            assert !Syskit::Composition.submodels.include?(m1)
            assert !Syskit::Component.submodels.include?(m2)
            assert !Syskit::Composition.submodels.include?(m2)
            assert !Syskit::Component.submodels.include?(m11)
            assert !Syskit::Composition.submodels.include?(m11)
        end
    end

    describe "#connect" do
        it "can connect ports" do
            component = simple_composition_model
            composition = Syskit::Composition.new_submodel 
            composition.add simple_component_model, :as => 'source'
            composition.add simple_component_model, :as => 'sink'
            composition.connect composition.source => composition.sink
            assert_equal({['source', 'sink'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        end
    end

    describe "#each_explicit_connection" do
        it "applies port mappings on overloads" do
            service, component, _ = models
            service1 = Syskit::DataService.new_submodel do
                input_port 'specialized_in', '/int'
                output_port 'specialized_out', '/int'
                provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
            end
            component.provides service1, :as => 'srv1'

            base = Syskit::Composition.new_submodel do
                add service, :as => 'srv'
            end

            composition = base.new_submodel
            composition.overload('srv', service1)

            base.add(service, :as => 'srv_in')
            base.connect(base.srv => base.srv_in)

            assert_equal([[ ['srv', 'srv_in'], {['specialized_out', 'srv_in'] => {}} ]], composition.each_explicit_connection.to_a)
            composition.overload('srv_in', service1)
            assert_equal([[ ['srv', 'srv_in'], {['specialized_out', 'specialized_in'] => {}} ]], composition.each_explicit_connection.to_a)

            composition = composition.new_submodel
            composition.overload('srv', component)
            assert_equal([[ ['srv', 'srv_in'], {['out', 'specialized_in'] => {}} ]], composition.each_explicit_connection.to_a)
            composition.overload('srv_in', component)
            assert_equal([[ ['srv', 'srv_in'], {['out', 'in'] => {}} ]], composition.each_explicit_connection.to_a)
        end
    end

    # Helper method to compare Port objects
    def assert_single_export(expected_name, expected_port, exports)
        exports = exports.to_a
        assert_equal(1, exports.size)
        export_name, exported_port = *exports.first
        assert_equal expected_name, export_name
        assert_equal expected_name, exported_port.name
        assert(exported_port.same_port?(expected_port), "expected #{expected_port} but got #{exported_port}")
    end

    describe "the port export functionality" do
        describe "#export" do
            it "promotes exported input ports by setting the new name and component model but keeps the orogen model" do
                service = Syskit::DataService.new_submodel { input_port 'in', '/int' }
                composition = Syskit::Composition.new_submodel { add service, :as => 'srv' }
                exported_port = composition.export composition.srv_child.in_port, :as => 'srv_in'
                assert_equal Syskit::Models::InputPort.new(composition, composition.srv_child.in_port.orogen_model, 'srv_in'),
                    exported_port
                assert_equal composition.find_port('srv_in'), exported_port
            end
            it "promotes exported output ports by setting the new name and component model but keeps the orogen model" do
                service = Syskit::DataService.new_submodel { output_port 'out', '/int' }
                composition = Syskit::Composition.new_submodel { add service, :as => 'srv' }
                exported_port = composition.export composition.srv_child.out_port, :as => 'srv_out'
                assert_equal Syskit::Models::OutputPort.new(composition, composition.srv_child.out_port.orogen_model, 'srv_out'),
                    exported_port
                assert_equal composition.find_port('srv_out'), exported_port
            end
        end

        describe "#find_exported_output" do
            it "returns the actual output port" do
                assert_equal simple_composition_model.srv_child.srv_out_port,
                    simple_composition_model.find_exported_output('srv_out')
            end
            it "returns nil for unknown ports" do
                assert !simple_composition_model.find_exported_output('bla')
            end
        end
        describe "#find_exported_input" do
            it "returns the actual input port" do
                assert_equal simple_composition_model.srv_child.srv_in_port,
                    simple_composition_model.find_exported_input('srv_in')
            end
            it "returns nil for unknown ports" do
                assert !simple_composition_model.find_exported_input('bla')
            end
        end
        describe "#exported_port?" do
            it "allows to test whether a child port is exported with #exported_port?" do
                assert simple_composition_model.exported_port?(simple_composition_model.srv_child.srv_in_port)
                assert !simple_composition_model.exported_port?(simple_composition_model.srv2_child.srv_in_port)
            end
        end
    end

    describe "#find_children_models_and_tasks" do
        it "computes port mappings for selected children" do
            service, component, composition = models
            context = Syskit::DependencyInjectionContext.new('srv' => component)
            explicit, _ = composition.find_children_models_and_tasks(context)
            assert_equal({'srv_in' => 'in', 'srv_out' => 'out'}, explicit['srv'].port_mappings)
        end
    end

    describe "#instanciate" do
        it "applies port mappings from dependency injection on exported ports" do
            service, component, composition = models
            composition = flexmock(composition)
            component = flexmock(component)

            # Make sure the forwarding is set up with the relevant port mapping
            # applied
            component.new_instances.should_receive(:forward_ports).
                with(composition, ['out', 'srv_out']=>{}).
                once
            composition.new_instances.should_receive(:forward_ports).
                with(component, ['srv_in', 'in']=>{}).
                once

            context = Syskit::DependencyInjectionContext.new('srv' => component)
            composition.instanciate(orocos_engine, context)
        end
    end

    describe "composition submodels" do
        describe "port mappings" do
            it "is applied on exported ports" do
                service, component, composition = models
                service1 = Syskit::DataService.new_submodel(:name => "Service1") do
                    input_port 'specialized_in', '/int'
                    output_port 'specialized_out', '/int'
                    provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
                end
                component.provides service1, :as => 'srv1'

                c0 = composition.new_submodel(:name => "C0")
                c0.overload('srv', service1)
                assert_single_export 'srv_in', c0.srv_child.specialized_in_port, c0.each_exported_input
                assert_single_export 'srv_out', c0.srv_child.specialized_out_port, c0.each_exported_output

                c1 = c0.new_submodel(:name => "C1")
                c1.overload('srv', component)
                # Re-test for c0 to make sure that the overload did not touch the base
                # model
                assert_single_export 'srv_in', c0.srv_child.specialized_in_port, c0.each_exported_input
                assert_single_export 'srv_out', c0.srv_child.specialized_out_port, c0.each_exported_output
                puts c0.srv_child.specialized_in_port
                assert_single_export 'srv_in', c1.srv_child.in_port, c1.each_exported_input
                assert_single_export 'srv_out', c1.srv_child.out_port, c1.each_exported_output
            end
        end

        describe "#add" do
            it "computes port mappings when overloading a child" do
                service, component, composition = models
                service1 = Syskit::DataService.new_submodel(:name => "Service1") do
                    input_port 'specialized_in', '/int'
                    output_port 'specialized_out', '/int'
                    provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
                end
                component.provides service1, :as => 'srv1'

                c0 = composition.new_submodel(:name => "C0")
                c0.overload('srv', service1)
                child = c0.find_child('srv')
                assert_same composition.find_child('srv'), child.overload_info.required
                assert_equal [service], child.overload_info.required.base_models.to_a
                assert_equal [service1], child.overload_info.selected.base_models.to_a
                assert_equal Hash['srv_in' => 'specialized_in', 'srv_out' => 'specialized_out'],
                    child.port_mappings

                c1 = c0.new_submodel(:name => "C1")
                c1.overload('srv', component)
                child = c1.find_child('srv')
                assert_same c0.find_child('srv'), child.overload_info.required
                assert_equal [service1], child.overload_info.required.base_models.to_a
                assert_equal [component], child.overload_info.selected.base_models.to_a
                assert_equal Hash['specialized_in' => 'in', 'specialized_out' => 'out'],
                    child.port_mappings
            end
        end
    end
end

