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

    module DefinitionModule
        # Module used when we want to do some "public" models
    end

    def simple_models
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
        Roby.app.filter_backtraces = false
	super

        srv = @simple_service_model = DataService.new_submodel(:name => "SimpleServiceModel") do
            input_port 'srv_in', '/int'
            output_port 'srv_out', '/int'
        end
        @simple_component_model = TaskContext.new_submodel(:name => "SimpleComponentModel") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_component_model.provides simple_service_model, :as => 'srv',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_task_model = TaskContext.new_submodel(:name => "SimpleTaskModel") do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        simple_task_model.provides simple_service_model, :as => 'srv',
            'srv_in' => 'in', 'srv_out' => 'out'
        @simple_composition_model = Composition.new_submodel(:name => "SimpleCompositionModel") do
            add srv, :as => 'srv'
            export self.srv_child.srv_in_port
            export self.srv_child.srv_out_port
            provides srv, :as => 'srv'
        end
    end

    def teardown
        super
        begin DefinitionModule.send(:remove_const, :Cmp)
        rescue NameError
        end
    end

    def setup_with_port_mapping
        return simple_service_model, simple_component_model, simple_composition_model
    end

    def test_new_submodel_registers_the_submodel
        submodel = Composition.new_submodel
        subsubmodel = submodel.new_submodel

        assert Component.submodels.include?(submodel)
        assert Component.submodels.include?(subsubmodel)
        assert Composition.submodels.include?(submodel)
        assert Composition.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_new_submodel_does_not_register_the_submodels_on_provided_services
        submodel = Composition.new_submodel
        ds = DataService.new_submodel
        submodel.provides ds, :as => 'srv'
        subsubmodel = submodel.new_submodel

        assert !ds.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_clear_submodels_removes_registered_submodels
        m1 = Composition.new_submodel
        m2 = Composition.new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert Component.submodels.include?(m1)
        assert Composition.submodels.include?(m1)
        assert Component.submodels.include?(m2)
        assert Composition.submodels.include?(m2)
        assert !Component.submodels.include?(m11)
        assert !Composition.submodels.include?(m11)

        m11 = m1.new_submodel
        Composition.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !Component.submodels.include?(m1)
        assert !Composition.submodels.include?(m1)
        assert !Component.submodels.include?(m2)
        assert !Composition.submodels.include?(m2)
        assert !Component.submodels.include?(m11)
        assert !Composition.submodels.include?(m11)
    end

    def test_definition_on_modules
        model = Composition.new_submodel
        DefinitionModule.const_set :Cmp, model
        assert_equal "TC_Models_Composition::DefinitionModule::Cmp", model.name
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

        composition = base.new_submodel
        composition.overload('srv', service1)

        base.add(service, :as => 'srv_in')
        base.connect(base.srv => base.srv_in)

        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'srv_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)
        composition.overload('srv_in', service1)
        assert_equal({['srv', 'srv_in'] => {['specialized_out', 'specialized_in'] => {}}}.to_set, composition.each_explicit_connection.to_set)

        composition = composition.new_submodel
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
        assert(exported_port.same_port?(expected_port), "expected #{expected_port} but got #{exported_port}")
    end

    def test_each_exported_input_output_renames_port
        service = DataService.new_submodel do
            input_port 'in', '/int'
            output_port 'out', '/int'
        end
        srv_in, srv_out = nil
        composition = Composition.new_submodel do
            add service, :as => 'srv'

            srv_in = self.srv_child.in_port
            export srv_in, :as => 'srv_in'
            srv_out = self.srv_child.out_port
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
        service1 = DataService.new_submodel(:name => "Service1") do
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

    def test_overload_computes_port_mappings
        service, component, composition = setup_with_port_mapping
        service1 = DataService.new_submodel(:name => "Service1") do
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
        specialized_model = composition.specialize('srv' => component)
        composition = composition.instanciate_specialization(specialized_model)
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
end

