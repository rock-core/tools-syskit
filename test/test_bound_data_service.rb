require 'syskit'
require 'syskit/test'

class TC_BoundDataService < Test::Unit::TestCase
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

    def test_find_input_port_gives_access_to_unmapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(task = component_model.new)
        stub_deployed_task("task", task)
        assert_same task.find_input_port('in_parent_unmapped'), service.find_input_port('in_parent_unmapped')
        assert_same task.find_input_port('in_base_unmapped'), service.find_input_port('in_base_unmapped')
    end

    def test_find_input_port_gives_access_to_mapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(task = component_model.new)
        stub_deployed_task("task", task)
        assert_same task.find_input_port('in_port'), service.find_input_port('in_model')
    end

    def test_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(component_model.new)
        assert !service.find_input_port('in_parent')
        assert !service.find_input_port('in_base')
    end

    def test_find_input_port_returns_nil_on_a_task_port_that_is_not_a_service_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(component_model.new)
        assert !service.find_input_port('other_port')
    end

    def test_narrowed_find_input_port_gives_access_to_unmapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(task = component_model.new)
        stub_deployed_task("task", task)
        assert_same task.find_input_port('in_parent_unmapped'), service.find_input_port('in_parent_unmapped')
        assert_same task.find_input_port('in_base_unmapped'), service.find_input_port('in_base_unmapped')
    end

    def test_narrowed_find_input_port_returns_nil_on_unmapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(base).bind(component_model.new)
        assert !service.find_input_port('in_parent_unmapped')
    end

    def test_narrowed_find_input_port_gives_access_to_mapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(task = component_model.new)
        stub_deployed_task("task", task)
        assert_same task.find_input_port('in_port'), service.find_input_port('in_parent')
    end

    def test_narrowed_find_input_port_returns_nil_on_mapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(component_model.new)
        assert !service.find_input_port('in_port')
    end

    def test_narrowed_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(component_model.new)
        assert !service.find_input_port('in_base')
    end

    def test_connect_ports_task_to_service
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        # the connect_ports call should translate service ports to actual ports
        # and pass on to add_sink
        flexmock(source_task).should_receive(:add_sink).
            once.with(sink_task, {['out_port', 'in_port'] => Hash.new})
        source_task.connect_ports(sink_task.test_srv,
            ['out_port', 'in_model'] => Hash.new)

        # Cannot connect to a port that is not part of the service
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task.test_srv,
                ['out_port', 'in_port'] => Hash.new)
        end
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task.test_srv,
                ['out_port', 'in_parent'] => Hash.new)
        end

        # Cannot connect to a completely nonexistent port
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task.test_srv,
                ['out_port', 'does_not_exist'] => Hash.new)
        end
    end

    def test_connect_ports_task_to_narrowed_service
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        sink = sink_task.test_srv.as(parent)

        # the connect_ports call should translate service ports to actual ports
        # and pass on to add_sink
        flexmock(source_task).should_receive(:add_sink).
            once.with(sink_task, {['out_port', 'in_port'] => Hash.new})
        source_task.connect_ports(sink,
            ['out_port', 'in_parent'] => Hash.new)

        # Cannot connect to a port that is not part of the service
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink,
                ['out_port', 'in_port'] => Hash.new)
        end
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink,
                ['out_port', 'in_model'] => Hash.new)
        end

        # Cannot connect to a completely nonexistent port
        assert_raises(ArgumentError) do
            source_task.connect_ports(sink,
                ['out_port', 'does_not_exist'] => Hash.new)
        end
    end

    def test_connect_ports_service_to_task
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        source = source_task.test_srv

        flexmock(source_task).should_receive(:add_sink).
            once.with(sink_task, {['out_port', 'in_port'] => Hash.new})
        source.connect_ports(sink_task,
            ['out_model', 'in_port'] => Hash.new)

        # Cannot connect to a port that is not part of the service
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['out_port', 'in_port'] => Hash.new)
        end
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['out_parent', 'in_port'] => Hash.new)
        end

        # Cannot connect to a completely nonexistent port
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['does_not_exist', 'in_port'] => Hash.new)
        end
    end

    def test_connect_ports_narrowed_service_to_task
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        source = source_task.test_srv.as(parent)

        flexmock(source_task).should_receive(:add_sink).
            once.with(sink_task, {['out_port', 'in_port'] => Hash.new})
        source.connect_ports(sink_task,
            ['out_parent', 'in_port'] => Hash.new)

        # Cannot connect to a port that is not part of the service
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['out_port', 'in_port'] => Hash.new)
        end
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['out_port', 'in_model'] => Hash.new)
        end

        # Cannot connect to a completely nonexistent port
        assert_raises(ArgumentError) do
            source.connect_ports(sink_task,
                ['out_port', 'does_not_exist'] => Hash.new)
        end
    end

    def test_fullfills_p
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.bind(component_model.new)

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
        service = service.bind(component_model.new)

        other_service = DataService.new_submodel
        component_model.provides other_service, :as => 'unrelated_service'

        assert_equal [base,parent,model,DataService,component_model].to_set,
            service.each_fullfilled_model.to_set
    end
end

