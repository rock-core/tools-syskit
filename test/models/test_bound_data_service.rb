require 'syskit'
require 'syskit/test'

class TC_Models_BoundDataService < Test::Unit::TestCase
    include Syskit::SelfTest

    DataService = Syskit::DataService

    def setup_stereocamera
        service_model = DataService.new_submodel do
            output_port 'image', '/int'
        end
        other_service_model = DataService.new_submodel
        component_model = Syskit::TaskContext.new_submodel do
            output_port 'left', '/int'
            output_port 'right', '/int'
        end
        left_srv  = component_model.provides service_model, :as => 'left', 'image' => 'left'
        right_srv = component_model.provides service_model, :as => 'right', 'image' => 'right'
        component_model.provides other_service_model, :as => 'other_srv'
        return service_model, other_service_model, component_model, left_srv, right_srv
    end

    def setup_transitive_services
        base = DataService.new_submodel do
            input_port "in_base", "/int"
            input_port 'in_base_unmapped', '/double'
            output_port "out_base", "/int"
            output_port 'out_base_unmapped', '/double'
        end
        parent = DataService.new_submodel do
            input_port "in_parent", "/int"
            input_port 'in_parent_unmapped', '/double'
            output_port "out_parent", "/int"
            output_port 'out_parent_unmapped', '/double'
        end
        parent.provides base, 'in_base' => 'in_parent', 'out_base' => 'out_parent'
        model = DataService.new_submodel do
            input_port "in_model", "/int"
            output_port "out_model", "/int"
        end
        model.provides parent, 'in_parent' => 'in_model', 'out_parent' => 'out_model'

        component_model = Syskit::TaskContext.new_submodel do
            input_port 'in_port', '/int'
            output_port 'out_port', '/int'
            output_port 'other_port', '/int'

            input_port 'in_parent_unmapped', '/double'
            input_port 'in_base_unmapped', '/double'
            output_port 'out_parent_unmapped', '/double'
            output_port 'out_base_unmapped', '/double'
        end
        service = component_model.provides(model,
                    :as => 'test',
                    'in_model' => 'in_port',
                    'out_model' => 'out_port')

        return base, parent, model, component_model, service
    end

    def test_root_service
        component_model = TaskContext.new_submodel
        service_model = DataService.new_submodel
        other_service_model = DataService.new_submodel
        service = component_model.provides service_model, :as => 'service'
        component_model.provides other_service_model, :as => 'other_service'
        assert_equal component_model, service.component_model
        assert service.master?
        assert_equal('service', service.full_name)
        assert_equal('service', service.name)
        assert(service.fullfills?(service_model))
        assert(!service.fullfills?(other_service_model))
        assert(service.fullfills?(component_model))
        assert(service.fullfills?([component_model, service_model]))
    end

    def test_fullfills_p
        base, parent, model, component_model, service =
            setup_transitive_services

        other_service = DataService.new_submodel
        component_model.provides other_service, :as => 'unrelated_service'

        assert service.fullfills?(component_model)
        assert service.fullfills?(base)
        assert service.fullfills?(parent)
        assert service.fullfills?(model)
        assert !service.fullfills?(other_service)
    end

    def test_each_fullfilled_model
        base, parent, model, component_model, service =
            setup_transitive_services

        other_service = DataService.new_submodel
        component_model.provides other_service, :as => 'unrelated_service'

        assert_equal [base,parent,model,DataService,component_model].to_set,
            service.each_fullfilled_model.to_set
    end

    def test_port_mappings
        service_model, other_service_model, component_model, left_srv, right_srv =
            setup_stereocamera
        assert_equal({ 'image' => 'left' }, left_srv.port_mappings_for_task)
    end

    def test_slave_service_access_through_method_missing
        service = DataService.new_submodel
        component = TaskContext.new_submodel
        root = component.provides service, :as => 'root'
        slave = component.provides service, :as => 'slave', :slave_of => 'root'
        assert_same slave, root.slave_srv
    end

    def test_output_port_access_through_method_missing
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_same service.find_output_port('out_model'), service.out_model_port
    end

    def test_port_mappings_transitive_services
        base, parent, model, component_model, service =
            setup_transitive_services

        assert_equal({ 'in_model' => 'in_port',
                       'in_parent_unmapped' => 'in_parent_unmapped',
                       'in_base_unmapped' => 'in_base_unmapped',
                       'out_model' => 'out_port',
                       'out_parent_unmapped' => 'out_parent_unmapped',
                       'out_base_unmapped' => 'out_base_unmapped' },
                       service.port_mappings_for_task)
        assert_equal({ 'in_parent' => 'in_port',
                       'in_parent_unmapped' => 'in_parent_unmapped',
                       'in_base_unmapped' => 'in_base_unmapped',
                       'out_parent' => 'out_port',
                       'out_parent_unmapped' => 'out_parent_unmapped',
                       'out_base_unmapped' => 'out_base_unmapped' },
                       service.port_mappings_for(parent))
        assert_equal({ 'in_base' => 'in_port',
                       'in_base_unmapped' => 'in_base_unmapped',
                       'out_base' => 'out_port',
                       'out_base_unmapped' => 'out_base_unmapped' },
                       service.port_mappings_for(base))
    end

    def assert_ports_equal(component_model, names, result)
        result.each do |p|
            assert_same component_model, p.component_model
            assert names.include?(p.name), "#{p.name} was not expected to be in the port list #{names.to_a.sort.join(", ")}"
        end
    end

    def test_each_output_port
        base, parent, model, component_model, service =
            setup_transitive_services

        assert_ports_equal service, ['out_base_unmapped', 'out_parent_unmapped', 'out_model'],
            service.each_output_port
    end

    def test_each_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_ports_equal service, ['in_base_unmapped', 'in_parent_unmapped', 'in_model'],
            service.each_input_port
    end

    def test_narrowed_find_input_port_gives_access_to_unmapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent)
        assert service.find_input_port('in_parent_unmapped')
        assert service.find_input_port('in_base_unmapped')
    end

    def test_narrowed_find_input_port_returns_nil_on_unmapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(base)
        assert !service.find_input_port('in_parent_unmapped')
    end

    def test_narrowed_find_input_port_gives_access_to_mapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent)
        assert service.find_input_port('in_parent')
    end

    def test_narrowed_find_input_port_returns_nil_on_mapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent)
        assert !service.find_input_port('in_port')
    end

    def test_narrowed_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent)
        assert !service.find_input_port('in_base')
    end

end

