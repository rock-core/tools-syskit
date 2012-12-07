require 'syskit'
require 'syskit/test'

class TC_Component < Test::Unit::TestCase
    include Syskit::SelfTest

    DataService = Syskit::DataService
    TaskContext = Syskit::TaskContext

    def test_get_bound_data_service_using_servicename_srv_syntax
        service_model = DataService.new_submodel
        component_model = TaskContext.new_submodel
        bound_service_model = component_model.provides(service_model, :as => 'test')
        plan.add(component = component_model.new)
        assert_equal(component.find_data_service('test'), component.test_srv)
    end

    def test_connect_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port 'out', '/double'
            input_port 'other', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })
        assert_equal({['out', 'out'] => {:type => :buffer, :size => 20 }},
                     source_task[sink_task, Syskit::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        source_task.connect_ports(sink_task, ['out', 'other'] => {:type => :buffer, :size => 30 })
        assert_equal(
            {
                ['out', 'out'] => {:type => :buffer, :size => 20 },
                ['out', 'other'] => {:type => :buffer, :size => 30 }
            }, source_task[sink_task, Syskit::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        assert(source_task.connected_to?('out', sink_task, 'other'))
    end

    def test_connect_ports_non_existent_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port 'out', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, ['out', 'does_not_exist'] => {:type => :buffer, :size => 20 })
        end
        assert(!Syskit::Flows::DataFlow.include?(source_task))
        assert(!Syskit::Flows::DataFlow.include?(sink_task))

        assert_raises(ArgumentError) do
            source_task.connect_ports(sink_task, ['does_not_exist', 'out'] => {:type => :buffer, :size => 20 })
        end
        assert(!Syskit::Flows::DataFlow.include?(source_task))
        assert(!Syskit::Flows::DataFlow.include?(sink_task))
        assert(!Syskit::Flows::DataFlow.include?(source_task))
        assert(!Syskit::Flows::DataFlow.include?(sink_task))
    end

    def test_disconnect_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        sink_model = Syskit::TaskContext.new_submodel do
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
            }, source_task[sink_task, Syskit::Flows::DataFlow])
        assert(source_task.connected_to?('out', sink_task, 'out'))
        assert(!source_task.connected_to?('out', sink_task, 'other'))
    end

    def test_disconnect_ports_non_existent_ports
        source_model = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        sink_model = Syskit::TaskContext.new_submodel do
            input_port 'out', '/double'
        end
        plan.add(source_task = source_model.new)
        plan.add(sink_task = sink_model.new)
        source_task.connect_ports(sink_task, ['out', 'out'] => {:type => :buffer, :size => 20 })

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['out', 'does_not_exist']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Syskit::Flows::DataFlow])

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['does_not_exist', 'out']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Syskit::Flows::DataFlow])

        assert_raises(ArgumentError) do
            source_task.disconnect_ports(sink_task, [['does_not_exist', 'does_not_exist']])
        end
        assert_equal(
            { ['out', 'out'] => {:type => :buffer, :size => 20 } }, source_task[sink_task, Syskit::Flows::DataFlow])
    end

    def test_disconnect_ports_non_existent_connection
        source_model = Syskit::TaskContext.new_submodel do
            output_port 'out', '/double'
        end
        sink_model = Syskit::TaskContext.new_submodel do
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
        model = Syskit::TaskContext.new_submodel :name => "Model"
        submodel = model.new_submodel :name => "Submodel"

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

    def test_data_reader_creates_reader_on_associated_port
        task = flexmock(Component.new)
        port = flexmock
        port.should_receive(:reader).once.and_return(expected = Object.new)
        task.should_receive(:find_output_port).once.with('out').and_return(port)
        assert_same expected, task.data_reader('out')
    end

    def test_data_reader_passes_policy
        task = flexmock(Component.new)
        port = flexmock
        policy = Hash[:pull => true, :type => :buffer, :size => 20]
        port.should_receive(:reader).once.with(policy)
        task.should_receive(:find_output_port).once.with('out').and_return(port)
        task.data_reader('out', policy)
    end

    def test_data_reader_raises_if_the_output_port_does_not_exist
        task = flexmock(Component.new)
        task.should_receive(:find_output_port).with('does_not_exist').and_return(nil)
        assert_raises(ArgumentError) { task.data_reader('does_not_exist') }
    end

    def test_data_reader_creates_reader_using_pull_by_default
        task = flexmock(Component.new)
        port = flexmock
        port.should_receive(:reader).
            once.with(:pull => true, :type => :buffer, :size => 20)
        task.should_receive(:find_output_port).
            once.with('out').and_return(port)
        task.data_reader('out', :type => :buffer, :size => 20)
    end

    def test_data_reader_allows_to_override_pull_flag
        task = flexmock(Component.new)
        port = flexmock
        port.should_receive(:reader).
            once.with(:pull => false, :type => :buffer, :size => 20)
        task.should_receive(:find_output_port).
            once.with('out').and_return(port)
        task.data_reader('out', :type => :buffer, :size => 20, :pull => false)
    end

    def test_data_writer_creates_writer_on_associated_port
        task = flexmock(Component.new)
        port = flexmock
        port.should_receive(:writer).once.and_return(expected = Object.new)
        task.should_receive(:find_input_port).once.with('in').and_return(port)
        assert_same expected, task.data_writer('in')
    end

    def test_data_writer_passes_policy
        task = flexmock(Component.new)
        port = flexmock
        policy = Hash[:type => :buffer, :size => 20]
        port.should_receive(:writer).once.with(policy)
        task.should_receive(:find_input_port).once.with('in').and_return(port)
        task.data_writer('in', policy)
    end

    def test_data_writer_raises_if_the_port_does_not_exist
        task = flexmock(Component.new)
        port = flexmock
        task.should_receive(:find_input_port).once.with('in')
        assert_raises(ArgumentError) { task.data_writer('in') }
    end
end


