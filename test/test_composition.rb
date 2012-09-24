BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_Composition < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def setup_with_port_mapping
        service = sys_model.data_service_type("Service") do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        component = mock_roby_component_model("Component") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        component.provides service, 'srv_in' => 'in', 'srv_out' => 'out'

        composition = mock_roby_composition_model("OdometryComposition") do
            add service, :as => 'srv'
            export self.srv.srv_in
            export self.srv.srv_out
            provides service
        end
        return service, component, composition
    end

    def test_explicit_connection
        component = mock_roby_component_model("Component") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        composition = mock_roby_composition_model("Composition") do
            add component, :as => 'source'
            add component, :as => 'sink'
            connect source => sink
        end
        assert_equal({['source', 'sink'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
    end

    def test_explicit_connection_applies_port_mappings
        service, component, base = setup_with_port_mapping
        service1 = sys_model.data_service_type('SpecializedService') do
            input_port 'specialized_in', '/int'
            output_port 'specialized_out', '/int'
            provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
        end
        component.provides service1

        composition = Class.new(base)
        composition.overload('srv', service1)

        base.add(service, :as => 'srv_in')
        base.connect(base.srv => base.srv_in)

        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'srv_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        composition.overload('srv_in', service1)
        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'specialized_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)

        composition = Class.new(composition)
        composition.overload('srv', component)
        assert_equal({['srv', 'srv_in'] => {['out', 'specialized_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        composition.overload('srv_in', component)
        assert_equal({['srv', 'srv_in'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
    end

    def test_each_exported_input_output_applies_port_mappings
        service, component, composition = setup_with_port_mapping
        service1 = sys_model.data_service_type('SpecializedService') do
            input_port 'specialized_in', '/int'
            output_port 'specialized_out', '/int'
            provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
        end
        component.provides service1

        composition = Class.new(composition)
        composition.overload('srv', service1)
        assert_equal([['srv_in', composition.srv.specialized_in]], composition.each_exported_input.to_a)
        assert_equal([['srv_out', composition.srv.specialized_out]], composition.each_exported_output.to_a)

        composition = Class.new(composition)
        composition.overload('srv', component)
        assert_equal([['srv_in', composition.srv.in]], composition.each_exported_input.to_a)
        assert_equal([['srv_out', composition.srv.out]], composition.each_exported_output.to_a)
    end

    def test_child_selection_port_mappings
        service, component, composition = setup_with_port_mapping
        context = DependencyInjectionContext.new('srv' => component)
        explicit, _ = composition.find_children_models_and_tasks(context)
        assert_equal({'srv_in' => 'in', 'srv_out' => 'out'}, explicit['srv'].port_mappings)
    end

    def test_instanciate_applies_port_mappings
        service, component, composition = setup_with_port_mapping
        composition = flexmock(composition)

        # Make sure the forwarding is set up with the relevant port mapping
        # applied
        component.new_instances.should_receive(:forward_ports).
            with(composition, ['out', 'srv_out']=>{}).
            once
        composition.new_instances.should_receive(:forward_ports).
            with(component, ['srv_in', 'in']=>{}).
            once

        context = DependencyInjectionContext.new('srv' => component)
        composition.instanciate(orocos_engine, context)
    end

    def test_specialization_updates_connections
        service, component, composition = setup_with_port_mapping
        composition = composition.instanciate_specialization(composition.specialize('srv' => component))
        composition.each_explicit_connection
    end

    def test_specialization_of_service_applies_port_mappings
        service, component, composition = setup_with_port_mapping
        composition = composition.instanciate_specialization(composition.specialize('srv' => component))
        composition = flexmock(composition)

        # Make sure the forwarding is set up with the relevant port mapping
        # applied
        composition.new_instances.should_receive(:forward_ports).
            with(component, ['srv_in', 'in']=>{}).
            once
        component.new_instances.should_receive(:forward_ports).
            with(composition, ['out', 'srv_out']=>{}).
            once

        context = DependencyInjectionContext.new('srv' => component)
        composition.instanciate(orocos_engine, context)
    end
end

