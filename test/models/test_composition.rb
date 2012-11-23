require 'syskit'
require 'syskit/test'

class TC_Models_Composition < Test::Unit::TestCase
    include Syskit::SelfTest

    DataService = Syskit::DataService
    Composition = Syskit::Composition
    TaskContext = Syskit::TaskContext

    attr_reader :simple_component_model
    attr_reader :simple_task_model
    attr_reader :simple_service_model
    attr_reader :simple_composition_model

    def simple_models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
        Roby.app.filter_backtraces = false
	super

        srv = @simple_service_model = DataService.new_submodel do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        @simple_component_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_component_model.provides simple_service_model, :as => 'srv',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_task_model = TaskContext.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_task_model.provides simple_service_model, :as => 'srv',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_composition_model = Composition.new_submodel do
            add srv, :as => 'srv'
            export self.srv.srv_in
            export self.srv.srv_out
            provides srv, :as => 'srv'
        end
    end

    def setup_with_port_mapping
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def test_explicit_connection
        component = simple_composition_model
        composition = Composition.new_submodel 
        composition.add simple_component_model, :as => 'source'
        composition.add simple_component_model, :as => 'sink'
        composition.connect composition.source => composition.sink
        assert_equal({['source', 'sink'] => {['out', 'in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
    end

    def test_explicit_connection_applies_port_mappings
        service, component, base = setup_with_port_mapping
        service1 = DataService.new_submodel do
            input_port 'specialized_in', '/int'
            output_port 'specialized_out', '/int'
            provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
        end
        component.provides service1, :as => 'srv1'

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

    def assert_single_export(expected_name, expected_port, exports)
        exports = exports.to_a
        assert_equal(1, exports.size)
        export_name, exported_port = *exports.first
        assert_equal expected_name, export_name
        assert_equal expected_name, exported_port.name
        assert(exported_port.same_port?(expected_port))
    end

    def test_each_exported_input_output_renames_port
        service = DataService.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        srv_in, srv_out = nil
        composition = Composition.new_submodel do
            add service, :as => 'srv'

            srv_in = self.srv.in
            export srv_in, :as => 'srv_in'
            srv_out = self.srv.out
            export srv_out, :as => 'srv_out'
            provides service, :as => 'srv'
        end
        assert_single_export 'srv_out', srv_out, composition.each_exported_output
        assert_single_export 'srv_in', srv_in, composition.each_exported_input

        # Make sure that the name of the original port is not changed
        assert_equal 'out', srv_out.name
        assert_equal 'in', srv_in.name
    end

    def test_each_exported_input_output_applies_port_mappings
        service, component, composition = setup_with_port_mapping
        service1 = DataService.new_submodel do
            input_port 'specialized_in', '/int'
            output_port 'specialized_out', '/int'
            provides service, 'srv_out' => 'specialized_out', 'srv_in' => 'specialized_in'
        end
        component.provides service1, :as => 'srv1'

        c0 = Class.new(composition)
        c0.overload('srv', service1)
        assert_single_export 'srv_in', c0.srv.specialized_in, c0.each_exported_input
        assert_single_export 'srv_out', c0.srv.specialized_out, c0.each_exported_output

        c1 = Class.new(c0)
        c1.overload('srv', component)
        # Re-test for c0 to make sure that the overload did not touch the base
        # model
        assert_single_export 'srv_in', c0.srv.specialized_in, c0.each_exported_input
        assert_single_export 'srv_out', c0.srv.specialized_out, c0.each_exported_output
        assert_single_export 'srv_in', c1.srv.in, c1.each_exported_input
        assert_single_export 'srv_out', c1.srv.out, c1.each_exported_output
    end

    def test_child_selection_port_mappings
        service, component, composition = setup_with_port_mapping
        context = Syskit::DependencyInjectionContext.new('srv' => component)
        explicit, _ = composition.find_children_models_and_tasks(context)
        assert_equal({'srv_in' => 'in', 'srv_out' => 'out'}, explicit['srv'].port_mappings)
    end

    def test_instanciate_applies_port_mappings
        service, component, composition = setup_with_port_mapping
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

    def test_specialization_updates_connections
        service, component, composition = setup_with_port_mapping
        composition = composition.instanciate_specialization(composition.specialize('srv' => component))
        composition.each_explicit_connection
    end

    def test_specialization_of_service_applies_port_mappings
        service, component, composition = setup_with_port_mapping
        composition = composition.instanciate_specialization(composition.specialize('srv' => component))
        composition = flexmock(composition)
        component = flexmock(component)

        # Make sure the forwarding is set up with the relevant port mapping
        # applied
        composition.new_instances.should_receive(:forward_ports).
            with(component, ['srv_in', 'in']=>{}).
            once
        component.new_instances.should_receive(:forward_ports).
            with(composition, ['out', 'srv_out']=>{}).
            once

        context = Syskit::DependencyInjectionContext.new('srv' => component)
        composition.instanciate(orocos_engine, context)
    end

    def test_state_using_child_component
        cmp_model = Composition.new_submodel 
        cmp_model.add simple_task_model, :as => 'child'
        cmp_model.state.pose = cmp_model.child.out

        source = cmp_model.state.pose.data_source
        assert_equal source, cmp_model.child.out
        assert_equal source.type, cmp_model.state.pose.type

        cmp = instanciate_component(cmp_model)
        flexmock(cmp).should_receive(:execute).and_yield
        flexmock(cmp).should_receive(:data_reader).with('child', 'out').once.and_return(reader = flexmock)
        cmp.resolve_state_sources
        assert_equal reader, cmp.state.data_sources.pose.reader
    end

    def test_state_using_child_service
        cmp_model = Composition.new_submodel 
        cmp_model.add simple_service_model, :as => 'child'
        cmp_model.state.pose = cmp_model.child.srv_out

        source = cmp_model.state.pose.data_source
        assert_equal source, cmp_model.child.srv_out
        assert_equal source.type, cmp_model.state.pose.type

        cmp = instanciate_component(cmp_model.use('child' => simple_task_model))
        flexmock(cmp).should_receive(:execute).and_yield
        flexmock(cmp).should_receive(:data_reader).with('child', 'srv_out').once.and_return(reader = flexmock)
        cmp.resolve_state_sources
        assert_equal reader, cmp.state.data_sources.pose.reader
    end
end

