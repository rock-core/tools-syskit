require 'syskit'
require 'syskit/test'

class TC_Models_BoundDataService < Test::Unit::TestCase
    include Syskit::SelfTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

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

    def test_creation
        service_model, other_service_model, component_model, left_srv, right_srv =
            setup_stereocamera
        assert_equal component_model, left_srv.component_model
        assert !left_srv.master
        assert_equal('left', left_srv.full_name)
        assert(left_srv.fullfills?(service_model))
        assert(!left_srv.fullfills?(other_service_model))
        assert(left_srv.fullfills?(component_model))
        assert(left_srv.fullfills?([component_model, service_model]))
    end

    def test_port_mappings
        service_model, other_service_model, component_model, left_srv, right_srv =
            setup_stereocamera
        assert_equal({ 'image' => 'left' }, left_srv.port_mappings_for_task)
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

    def test_each_task_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [component_model.out_base_unmapped, component_model.out_parent_unmapped, component_model.out_port].map(&:model).to_set,
             service.each_task_output_port.to_set)
    end

    def test_each_task_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [component_model.in_base_unmapped, component_model.in_parent_unmapped, component_model.in_port].map(&:model).to_set,
             service.each_task_input_port.to_set)
    end

    def test_each_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [model.out_base_unmapped, model.out_parent_unmapped, model.out_model].map(&:model).to_set,
             service.each_output_port.to_set)
    end

    def test_each_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [model.in_base_unmapped, model.in_parent_unmapped, model.in_model].map(&:model).to_set,
             service.each_input_port.to_set)
    end

    def test_as
        base, parent, model, component_model, service =
            setup_transitive_services
        narrowed = service.as(parent)

        assert_equal({ 'in_parent' => 'in_port',
                       'in_parent_unmapped' => 'in_parent_unmapped',
                       'in_base_unmapped' => 'in_base_unmapped',
                       'out_parent' => 'out_port',
                       'out_parent_unmapped' => 'out_parent_unmapped',
                       'out_base_unmapped' => 'out_base_unmapped' },
                       narrowed.port_mappings_for_task)
        assert_equal({ 'in_base' => 'in_port',
                       'in_base_unmapped' => 'in_base_unmapped',
                       'out_base' => 'out_port',
                       'out_base_unmapped' => 'out_base_unmapped' },
                       narrowed.port_mappings_for(base))

        assert(!narrowed.find_output_port('out_port'))
        assert(!narrowed.find_output_port('in_port'))
        assert(!narrowed.find_output_port('other_port'))
        assert(!narrowed.find_output_port('in_model'))
        assert(!narrowed.find_output_port('in_base'))
        assert(!narrowed.find_output_port('out_model'))
        assert(!narrowed.find_output_port('out_base'))
        assert_equal(parent.find_output_port('out_parent'),
                     narrowed.find_output_port('out_parent'))
        assert_equal(parent.find_output_port('out_parent_unmapped'),
                     narrowed.find_output_port('out_parent_unmapped'))
        assert_equal(parent.find_output_port('out_base_unmapped'),
                     narrowed.find_output_port('out_base_unmapped'))
    end

    def test_narrowed_model_each_task_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        assert_equal(
            [component_model.out_base_unmapped, component_model.out_parent_unmapped, component_model.out_port].map(&:model).to_set,
             service.each_task_output_port.to_set)
    end

    def test_narrowed_model_each_task_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        assert_equal(
            [component_model.in_base_unmapped, component_model.in_parent_unmapped, component_model.in_port].map(&:model).to_set,
             service.each_task_input_port.to_set)
    end

    def test_narrowed_model_each_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        assert_equal(
            [parent.out_base_unmapped, parent.out_parent_unmapped, parent.out_parent].map(&:model).to_set,
             service.each_output_port.to_set)
    end

    def test_narrowed_model_find_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        service.each_output_port do |p|
            assert_same(p, service.find_output_port(p.name))
        end
    end

    def test_narrowed_model_each_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        assert_equal(
            [parent.in_base_unmapped, parent.in_parent_unmapped, parent.in_parent].map(&:model).to_set,
             service.each_input_port.to_set)

        service.each_output_port do |p|
            assert_same(p, service.find_output_port(p.name))
        end
    end

    def test_narrowed_model_find_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.as(parent)
        service.each_input_port do |p|
            assert_same(p, service.find_input_port(p.name))
        end
    end
end

