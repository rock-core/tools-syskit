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
        component.provides service, :as => 'image'

        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
        assert_equal(service, component.find_data_service('image').model)
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
        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(bound_service))
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
        assert(component.fullfills?(service))
        assert_equal({'out' => 'other'}, component.port_mappings_for(service))
        assert_equal({'out' => 'other'}, component.port_mappings_for(bound_service))
    end

    def test_port_mappings_for_raises_for_unknown_service_types
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        assert_raises(ArgumentError) { component.port_mappings_for(service) }
    end

    def test_port_mappings_for_services_that_are_provided_multiple_times
        service = DataService.new_submodel do
            output_port 'image', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'left', '/int'
            output_port 'right', '/int'
        end
        left = component.provides service, :as => 'left', 'image' => 'left'
        right = component.provides service, :as => 'right', 'image' => 'right'
        assert_raises(Syskit::AmbiguousServiceSelection) { component.port_mappings_for(service) }
        assert_equal({'image' => 'left'}, component.port_mappings_for(left))
        assert_equal({'image' => 'right'}, component.port_mappings_for(right))
    end

    def test_provides_automatic_mapping_on_type
        service = DataService.new_submodel do
            output_port 'out', '/int'
        end
        component = TaskContext.new_submodel do
            output_port 'out', '/double'
            output_port 'other', '/int'
        end
        component.provides service, :as => 'srv'
        assert_equal({'out' => 'other'}, component.port_mappings_for(service))
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
        component.provides(service, :as => 'srv')
        assert_equal({'out' => 'other2'}, component.port_mappings_for(service))

        # Ambiguous type mapping, exact match on the name
        component = TaskContext.new_submodel do
            output_port 'out', '/int'
            output_port 'other2', '/int'
        end
        component.provides(service, :as => 'srv')
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
    end
end


