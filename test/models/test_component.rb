require 'syskit'
require 'syskit/test'

class TC_Models_Component < Test::Unit::TestCase
    include Syskit::SelfTest

    DataService = Syskit::DataService
    TaskContext = Syskit::TaskContext

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_new_submodel_registers_the_submodel
        submodel = Component.new_submodel
        subsubmodel = submodel.new_submodel

        assert Component.submodels.include?(submodel)
        assert Component.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_clear_submodels_removes_registered_submodels
        m1 = Component.new_submodel
        m2 = Component.new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert Component.submodels.include?(m1)
        assert Component.submodels.include?(m2)
        assert !Component.submodels.include?(m11)

        m11 = m1.new_submodel
        Component.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !Component.submodels.include?(m1)
        assert !Component.submodels.include?(m2)
        assert !Component.submodels.include?(m11)
    end

    def test_provides
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        bound_service = component.provides service, :as => 'image'

        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, bound_service.port_mappings_for_task)
        assert_equal(service, component.find_data_service('image').model)
    end

    def test_new_submodel_can_give_name_to_anonymous_models
        assert_equal 'C', Component.new_submodel(:name => 'C').name
    end

    def test_short_name_returns_name_if_there_is_one
        assert_equal 'C', Component.new_submodel(:name => 'C').short_name
    end

    def test_short_name_returns_to_s_if_there_are_no_name
        m = Component.new_submodel
        flexmock(m).should_receive(:to_s).and_return("my_name").once
        assert_equal 'my_name', m.short_name
    end

    def test_provides_uses_the_service_name_if_available
        service = DataService.new_submodel(:name => "MyServiceModel")
        component = TaskContext.new_submodel
        srv = component.provides service
        assert_equal "my_service_model", srv.name
    end

    def test_provides_raises_if_the_service_has_no_name_and_none_is_given
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert_raises(ArgumentError) { component.provides(service) }
    end

    def test_find_data_service_returns_nil_on_unknown_service
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        assert(!component.find_data_service('does_not_exist'))
    end

    def test_provides_explicit_name
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        bound_service = component.provides service, :as => 'camera'
        assert_equal(bound_service, component.find_data_service('camera'))
    end

    def test_provides_refuses_to_add_a_service_with_an_existing_name
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'
        assert_raises(ArgumentError) { component.provides(service, :as => 'srv') }
    end

    def test_provides_allows_to_overload_parent_services
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'
        submodel = component.new_submodel
        submodel.provides service, :as => 'srv'
    end

    def test_provides_raises_if_a_service_overload_is_with_an_incompatible_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        component.provides service, :as => 'srv'

        other_service = DataService.new_submodel
        submodel = component.new_submodel
        assert_raises(ArgumentError) { submodel.provides other_service, :as => 'srv' }
    end

    def test_provides_allows_to_setup_slave_services
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root_srv = component.provides service, :as => 'root'
        slave_srv = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_equal [slave_srv], root_srv.each_slave.to_a
        assert_same slave_srv, component.find_data_service('root.srv')
    end

    def test_each_slave_data_service
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_equal [slave].to_set, component.each_slave_data_service(root).to_set
    end

    def test_each_slave_data_service_on_submodel
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave = component.provides service, :as => 'srv', :slave_of => 'root'
        component = component.new_submodel
        assert_equal [slave.attach(component)], component.each_slave_data_service(root).to_a
    end

    def test_each_slave_data_service_on_submodel_with_new_slave
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root  = component.provides service, :as => 'root'
        slave1 = component.provides service, :as => 'srv1', :slave_of => 'root'
        component = component.new_submodel
        slave2 = component.provides service, :as => 'srv2', :slave_of => 'root'
        assert_equal [slave1.attach(component), slave2].to_a, component.each_slave_data_service(root).sort_by { |srv| srv.full_name }
    end

    def test_slave_can_have_the_same_name_than_a_root_service
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root_srv = component.provides service, :as => 'root'
        srv = component.provides service, :as => 'srv'
        root_srv = component.provides service, :as => 'srv', :slave_of => 'root'
        assert_same srv, component.find_data_service('srv')
        assert_same root_srv, component.find_data_service('root.srv')
    end

    def test_slave_enumeration_includes_parent_slaves_when_adding_a_slave_on_a_child_model
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root = component.provides service, :as => 'root'
        root_srv1 = component.provides service, :as => 'srv1', :slave_of => 'root'

        submodel = component.new_submodel
        root_srv2 = submodel.provides service, :as => 'srv2', :slave_of => 'root'
        assert_equal [root_srv1], component.root_srv.each_slave.to_a
        assert_equal [root_srv1.attach(submodel), root_srv2], submodel.root_srv.each_slave.sort_by(&:full_name)
    end

    def test_find_data_service_from_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert(!component.find_data_service_from_type(service))

        bound_service = component.provides service, :as => 'image'
        assert_equal(bound_service, component.find_data_service_from_type(service))

        bound_service = component.provides service, :as => 'camera'
        assert_raises(Syskit::AmbiguousServiceSelection) { component.find_data_service_from_type(service) }
    end

    def test_find_all_data_services_from_type
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert(component.find_all_data_services_from_type(service).empty?)

        bound_services = Set.new

        bound_services << component.provides(service, :as => 'image')
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)

        bound_services << component.provides(service, :as => 'camera')
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)
    end

    def test_provides_with_port_mappings
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
            output_port 'other', '/int'
        end
        bound_service = component.provides service, 'out' => 'other', :as => 'camera'
        assert_equal(bound_service, component.find_data_service('camera'))
        assert_equal({'out' => 'other'}, bound_service.port_mappings_for_task)
    end

    def test_provides_automatic_mapping_on_type
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/double'
            output_port 'other', '/int'
        end
        bound_service = component.provides service, :as => 'srv'
        assert_equal({'out' => 'other'}, bound_service.port_mappings_for_task)
    end

    def test_provides_validation
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        # No matching port
        component = TaskContext.new_submodel
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Wrong port direction
        component = TaskContext.new_submodel do
            input_port 'out', '/int'
        end
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, no exact match on the name
        component = TaskContext.new_submodel do
            output_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        assert_raises(Syskit::InvalidProvides) { component.provides(service, :as => 'srv') }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, one of the two possibilites has the wrong
        # direction
        component = TaskContext.new_submodel do
            input_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        bound_service = component.provides(service, :as => 'srv')
        assert_equal({'out' => 'other2'}, bound_service.port_mappings_for_task)

        # Ambiguous type mapping, exact match on the name
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
            output_port 'other2', '/int'
        end
        bound_service = component.provides(service, :as => 'srv')
        assert_equal({'out' => 'out'}, bound_service.port_mappings_for_task)
    end

    def test_has_output_port_returns_false_if_find_returns_false
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_output_port).with('p').and_return(Object.new)
        assert model.has_output_port?('p')
    end

    def test_has_output_port_returns_true_if_find_returns_true
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_output_port).with('p').and_return(nil)
        assert !model.has_output_port?('p')
    end

    def test_has_input_port_returns_false_if_find_returns_false
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_input_port).with('p').and_return(Object.new)
        assert model.has_input_port?('p')
    end

    def test_has_input_port_returns_true_if_find_returns_true
        model = Syskit::TaskContext.new_submodel
        flexmock(model).should_receive(:find_input_port).with('p').and_return(nil)
        assert !model.has_input_port?('p')
    end

    def test_find_output_port
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = output_port('p', '/double') }
        p = model.find_output_port('p')
        assert_equal 'p', p.name, 'p'
        assert_equal model, p.component_model
        assert_equal port_model, p.orogen_model
    end

    def test_find_output_port_returns_false_on_outputs
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = input_port('p', '/double') }
        assert !model.find_output_port('p')
    end

    def test_find_output_port_returns_false_on_non_existent_ports
        model = Syskit::TaskContext.new_submodel
        assert !model.find_output_port('p')
    end

    def test_find_input_port
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = input_port('p', '/double') }
        p = model.find_input_port('p')
        assert_equal 'p', p.name, 'p'
        assert_equal model, p.component_model
        assert_equal port_model, p.orogen_model
    end

    def test_find_input_port_returns_false_on_outputs
        port_model = nil
        model = Syskit::TaskContext.new_submodel { port_model = output_port('p', '/double') }
        assert !model.find_input_port('p')
    end

    def test_find_input_port_returns_false_on_non_existent_ports
        model = Syskit::TaskContext.new_submodel
        assert !model.find_input_port('p')
    end

    def test_find_data_service_return_value_is_bound_to_actual_model
        s = DataService.new_submodel
        c = Syskit::TaskContext.new_submodel { provides s, :as => 'srv' }
        sub_c = c.new_submodel
        assert_equal sub_c, sub_c.find_data_service('srv').component_model
    end

    def test_find_data_service_from_type_return_value_is_bound_to_actual_model
        s = DataService.new_submodel
        c = Syskit::TaskContext.new_submodel { provides s, :as => 'srv' }
        sub_c = c.new_submodel
        assert_equal sub_c, sub_c.find_data_service_from_type(s).component_model
    end
end


