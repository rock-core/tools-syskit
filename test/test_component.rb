BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_Component < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_model_provides
        service = sys_model.data_service_type("Image") do
            output_port 'out', '/int'
        end
        component = mock_roby_component_model do
            output_port 'out', '/int'
        end
        component.provides service

        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
        assert_equal(service, component.find_data_service('image').model)
    end

    def test_model_find_data_service_returns_nil_on_unknown_service
        component = mock_roby_component_model do
            output_port 'out', '/int'
        end
        assert(!component.find_data_service('does_not_exist'))
    end

    def test_model_provides_explicit_name
        service = sys_model.data_service_type("Image") do
            output_port 'out', '/int'
        end
        component = mock_roby_component_model do
            output_port 'out', '/int'
        end
        bound_service = component.provides service, :as => 'camera'

        assert_equal(bound_service, component.find_data_service('camera'))
        assert(component.fullfills?(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
        assert_equal({'out' => 'out'}, component.port_mappings_for(bound_service))
    end

    def test_model_find_data_service_from_type
        service = sys_model.data_service_type("Image")
        component = mock_roby_component_model
        assert(!component.find_data_service_from_type(service))

        bound_service = component.provides service
        assert_equal(bound_service, component.find_data_service_from_type(service))

        bound_service = component.provides service, :as => 'camera'
        assert_raises(AmbiguousServiceSelection) { component.find_data_service_from_type(service) }
    end

    def test_model_find_all_data_services_from_type
        service = sys_model.data_service_type("Image")
        component = mock_roby_component_model
        assert(component.find_all_data_services_from_type(service).empty?)

        bound_services = Set.new

        bound_services << component.provides(service)
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)

        bound_services << component.provides(service, :as => 'camera')
        assert_equal(bound_services,
                     component.find_all_data_services_from_type(service).to_set)
    end

    def test_model_provides_with_port_mappings
        service = sys_model.data_service_type("Image") do
            output_port 'out', '/int'
        end
        component = mock_roby_component_model do
            output_port 'out', '/int'
            output_port 'other', '/int'
        end
        bound_service = component.provides service, 'out' => 'other', :as => 'camera'
        assert_equal(bound_service, component.find_data_service('camera'))
        assert(component.fullfills?(service))
        assert_equal({'out' => 'other'}, component.port_mappings_for(service))
        assert_equal({'out' => 'other'}, component.port_mappings_for(bound_service))
    end

    def test_model_port_mappings_for_raises_for_unknown_service_types
        service = sys_model.data_service_type("Image")
        component = mock_roby_component_model
        assert_raises(ArgumentError) { component.port_mappings_for(service) }
    end

    def test_model_port_mappings_for_services_that_are_provided_multiple_times
        service = sys_model.data_service_type("Image") do
            output_port 'image', '/int'
        end
        component = mock_roby_component_model do
            output_port 'left', '/int'
            output_port 'right', '/int'
        end
        left = component.provides service, :as => 'left', 'image' => 'left'
        right = component.provides service, :as => 'right', 'image' => 'right'
        assert_raises(Orocos::RobyPlugin::AmbiguousServiceSelection) { component.port_mappings_for(service) }
        assert_equal({'image' => 'left'}, component.port_mappings_for(left))
        assert_equal({'image' => 'right'}, component.port_mappings_for(right))
    end

    def test_model_provides_automatic_mapping_on_type
        service = sys_model.data_service_type("Image") do
            output_port 'out', '/int'
        end
        component = mock_roby_component_model do
            output_port 'out', '/double'
            output_port 'other', '/int'
        end
        component.provides service
        assert_equal({'out' => 'other'}, component.port_mappings_for(service))
    end

    def test_model_provides_validation
        service = sys_model.data_service_type("Image") do
            output_port 'out', '/int'
        end
        # No matching port
        component = mock_roby_component_model
        assert_raises(InvalidProvides) { component.provides service }
        assert(!component.find_data_service_from_type(service))

        # Wrong port direction
        component = mock_roby_component_model do
            input_port 'out', '/int'
        end
        assert_raises(InvalidProvides) { component.provides service }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, no exact match on the name
        component = mock_roby_component_model do
            output_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        assert_raises(InvalidProvides) { component.provides service }
        assert(!component.find_data_service_from_type(service))

        # Ambiguous type mapping, one of the two possibilites has the wrong
        # direction
        component = mock_roby_component_model do
            input_port 'other1', '/int'
            output_port 'other2', '/int'
        end
        component.provides service
        assert_equal({'out' => 'other2'}, component.port_mappings_for(service))

        # Ambiguous type mapping, exact match on the name
        component = mock_roby_component_model do
            output_port 'out', '/int'
            output_port 'other2', '/int'
        end
        component.provides service
        assert_equal({'out' => 'out'}, component.port_mappings_for(service))
    end

    def test_model_direct_access_to_bound_services
        service_model = sys_model.data_service_type("Image")
        component_model = mock_roby_component_model
        bound_service = component_model.provides service_model, :as => 'test'
        assert_equal(bound_service, component_model.test_srv)
    end

    def test_direct_access_to_bound_services
        service_model = sys_model.data_service_type("Image")
        component_model = mock_roby_component_model
        bound_service_model = component_model.provides(service_model, :as => 'test')
        plan.add(component = component_model.new)
        assert_equal(component.find_data_service('test'), component.test_srv)
    end

    def test_connect_ports
        source_model = mock_roby_component_model do
            output_port 'out', '/double'
        end
        sink_model = mock_roby_component_model do
            input_port 'out', '/double'
            input_port 'other', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })
        assert_equal({['out', 'out'] => {:type => :buffer, :size => 20 }},
                     source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        source_task.connect_ports(sink_task, ['out', 'other'] => {:type => :buffer, :size => 30 })
        assert_equal(
            {
                ['out', 'out'] => {:type => :buffer, :size => 20 },
                ['out', 'other'] => {:type => :buffer, :size => 30 }
            }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        assert(source_task.connected_to?('out', sink_task, 'other'))
    end

    def test_connect_ports_non_existent_ports
        source_model = mock_roby_component_model do
            output_port 'out', '/double'
        end
        sink_model = mock_roby_component_model do
            input_port 'out', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, ['out', 'does_not_exist'] => {:type => :buffer, :size => 20 })
        end
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, ['does_not_exist', 'out'] => {:type => :buffer, :size => 20 })
        end
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, ['does_not_exist', 'does_not_exist'] => {:type => :buffer, :size => 20 })
        end
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(source_task))
        assert(!Orocos::RobyPlugin::Flows::DataFlow.include?(sink_task))
    end

    def test_disconnect_ports
        source_model = mock_roby_component_model do
            output_port 'out', '/double'
        end
        sink_model = mock_roby_component_model do
            input_port 'out', '/double'
            input_port 'other', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })
        source_task.connect_ports(sink_task, ['out', 'other'] => {:type => :buffer, :size => 30 })
        assert(source_task.connected_to?('out', sink_task, 'out'))
        assert(source_task.connected_to?('out', sink_task, 'other'))

        source_task.disconnect_ports(sink_task, [%w{out other}])
        assert_equal(
            {
                ['out', 'out'] => {:type => :buffer, :size => 20 }
            }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        assert(!source_task.connected_to?('out', sink_task, 'other'))
    end

    def test_disconnect_ports_non_existent_ports
        source_model = mock_roby_component_model do
            output_port 'out', '/double'
        end
        sink_model = mock_roby_component_model do
            input_port 'out', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['out', 'does_not_exist']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['does_not_exist', 'out']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['does_not_exist', 'does_not_exist']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Orocos::RobyPlugin::Flows::DataFlow])
    end

    def test_disconnect_ports_non_existent_connection
        source_model = mock_roby_component_model do
            output_port 'out', '/double'
        end
        sink_model = mock_roby_component_model do
            input_port 'out', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['out', 'out']])
        end
    end


    def test_merge_merges_explicit_fullfilled_model
        # TODO: make #fullfilled_model= and #fullfilled_model work on the same
        # format (currently, the writer wants [task_model, tags, arguments] and
        # the reader returns [models, arguments]
        model = mock_roby_component_model "Model"
        submodel = model.new_submodel "Submodel"

        plan.add(merged_task = model.new(:id => 'test'))
        merged_task.fullfilled_model = [Component, [], {:id => 'test'}]
        plan.add(merging_task = submodel.new)

        merging_task.merge(merged_task)
        assert_equal([[Component], {:id => 'test'}],
                     merging_task.fullfilled_model)

        plan.add(merged_task = model.new)
        merged_task.fullfilled_model = [Component, [], {:id => 'test'}]
        plan.add(merging_task = submodel.new(:id => 'test'))
        merging_task.fullfilled_model = [model, [], {}]

        merging_task.merge(merged_task)
        assert_equal([[model], {:id => 'test'}],
                     merging_task.fullfilled_model)
    end
end


