BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_BoundDataService < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def setup_stereocamera
        service_model = DataModel.new_submodel do
            output_port 'image', '/int'
        end
        other_service_model = DataModel.new_submodel
        component_model = mock_roby_component_model do
            output_port 'left', '/int'
            output_port 'right', '/int'
        end
        left_srv  = component_model.provides service_model, :as => 'left', 'image' => 'left'
        right_srv = component_model.provides service_model, :as => 'right', 'image' => 'right'
        component_model.provides other_service_model
        return service_model, other_service_model, component_model, left_srv, right_srv
    end

    def setup_transitive_services
        base = DataModel.new_submodel do
            input_port "in_base", "/int"
            input_port 'in_base_unmapped', '/double'
            output_port "out_base", "/int"
            output_port 'out_base_unmapped', '/double'
        end
        parent = DataModel.new_submodel do
            input_port "in_parent", "/int"
            input_port 'in_parent_unmapped', '/double'
            output_port "out_parent", "/int"
            output_port 'out_parent_unmapped', '/double'
        end
        parent.provides base, 'in_base' => 'in_parent', 'out_base' => 'out_parent'
        model = DataModel.new_submodel do
            input_port "in_model", "/int"
            output_port "out_model", "/int"
        end
        model.provides parent, 'in_parent' => 'in_model', 'out_parent' => 'out_model'

        component_model = mock_roby_component_model do
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

    def test_model_creation
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

    def test_model_port_mappings
        service_model, other_service_model, component_model, left_srv, right_srv =
            setup_stereocamera
        assert_equal({ 'image' => 'left' }, left_srv.port_mappings_for_task)
    end

    def test_model_port_mappings_transitive_services
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

    def test_model_each_task_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [component_model.out_base_unmapped, component_model.out_parent_unmapped, component_model.out_port].map(&:model).to_set,
             service.each_task_output_port.to_set)
    end

    def test_model_each_task_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [component_model.in_base_unmapped, component_model.in_parent_unmapped, component_model.in_port].map(&:model).to_set,
             service.each_task_input_port.to_set)
    end

    def test_model_each_output_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [model.out_base_unmapped, model.out_parent_unmapped, model.out_model].map(&:model).to_set,
             service.each_output_port.to_set)
    end

    def test_model_each_input_port
        base, parent, model, component_model, service =
            setup_transitive_services
        assert_equal(
            [model.in_base_unmapped, model.in_parent_unmapped, model.in_model].map(&:model).to_set,
             service.each_input_port.to_set)
    end

    def test_model_as
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

    # def test_connect_ports_non_existent_ports
    #     source_model = mock_roby_component_model do
    #         output_port 'out', '/double'
    #     end
    #     sink_model = mock_roby_component_model do
    #         input_port 'out', '/double'
    #     end
    #     plan.add(source_task = source_model.new)
    #     plan.add(sink_task = sink_model.new)

    #     assert_raises(ArgumentError) do
    #         source_task.connect_ports(sink_task, ['out', 'does_not_exist'] => {:type => :buffer, :size => 20 })
    #     end
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))

    #     assert_raises(ArgumentError) do
    #         source_task.connect_ports(sink_task, ['does_not_exist', 'out'] => {:type => :buffer, :size => 20 })
    #     end
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))

    #     assert_raises(ArgumentError) do
    #         source_task.connect_ports(sink_task, ['does_not_exist', 'does_not_exist'] => {:type => :buffer, :size => 20 })
    #     end
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
    #     assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))
    # end

    # def test_disconnect_ports
    #     source_model = mock_roby_component_model do
    #         output_port 'out', '/double'
    #     end
    #     sink_model = mock_roby_component_model do
    #         input_port 'out', '/double'
    #         input_port 'other', '/double'
    #     end
    #     plan.add(source_task = source_model.new)
    #     plan.add(sink_task = sink_model.new)
    #     source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })
    #     source_task.connect_ports(sink_task, ['out', 'other'] => {:type => :buffer, :size => 30 })
    #     source_task.disconnect_ports(sink_task, [%w{out other}])
    #     assert_equal(
    #         {
    #             ['out', 'out'] => {:type => :buffer, :size => 20 }
    #         }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
    # end

    # def test_disconnect_ports_non_existent_ports
    #     source_model = mock_roby_component_model do
    #         output_port 'out', '/double'
    #     end
    #     sink_model = mock_roby_component_model do
    #         input_port 'out', '/double'
    #     end
    #     plan.add(source_task = source_model.new)
    #     plan.add(sink_task = sink_model.new)
    #     source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })

    #     assert_raises(ArgumentError) do
    #         source_task.disconnect_ports(sink_task, [['out', 'does_not_exist']])
    #     end
    #     assert_equal(
    #         { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])

    #     assert_raises(ArgumentError) do
    #         source_task.disconnect_ports(sink_task, [['does_not_exist', 'out']])
    #     end
    #     assert_equal(
    #         { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])

    #     assert_raises(ArgumentError) do
    #         source_task.disconnect_ports(sink_task, [['does_not_exist', 'does_not_exist']])
    #     end
    #     assert_equal(
    #         { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
    # end

    # def test_disconnect_ports_non_existent_connection
    #     source_model = mock_roby_component_model do
    #         output_port 'out', '/double'
    #     end
    #     sink_model = mock_roby_component_model do
    #         input_port 'out', '/double'
    #     end
    #     plan.add(source_task = source_model.new)
    #     plan.add(sink_task = sink_model.new)
    #     assert_raises(ArgumentError) do
    #         source_task.disconnect_ports(sink_task, [['out', 'out']])
    #     end
    # end
end

