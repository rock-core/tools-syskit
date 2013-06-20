require 'syskit/test'

describe Syskit::Component do
    include Syskit::SelfTest

    describe "#specialize" do
        attr_reader :task, :task_m
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @task = task_m.new
        end

        it "should make sure that the task has its own private model" do
            task.specialize
            refute_same task_m, task.model
        end
        it "should be possible to declare that the specialized model provides a service without touching the source model" do
            task.specialize
            srv_m = Syskit::DataService.new_submodel
            task.model.provides srv_m, :as => 'srv'
            assert task.fullfills?(srv_m)
            assert !task_m.fullfills?(srv_m)
        end
        it "should create a specialized model with a submodel of the oroGen model" do
            task.specialize
            refute_same task_m.orogen_model, task.model.orogen_model
            assert_same task_m.orogen_model, task.model.orogen_model.superclass
        end

        it "should return true if it creates a new model" do
            task_m = Syskit::TaskContext.new_submodel
            task = task_m.new
            assert task.specialize
        end
        it "should not specialize an already specialized model, and return false" do
            task_m = Syskit::TaskContext.new_submodel
            task = task_m.new
            task.specialize
            current_model = task.model
            assert !task.specialize
            assert_same current_model, task.model
        end
    end

    describe "#require_dynamic_service" do
        attr_reader :task_m, :srv_m, :dyn, :task
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "int"
                dynamic_output_port /\w+_out/, "bool"
                dynamic_input_port /\w+_in/, "double"
            end
            srv_m = @srv_m = Syskit::DataService.new_submodel do
                output_port "out", "bool"
                input_port "in", "double"
            end
            @dyn = task_m.dynamic_service srv_m, :as => "dyn" do
                provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
            end
            @task = task_m.new
        end

        it "replaces the task with a specialized version of it" do
            flexmock(task).should_receive(:specialize).once.pass_thru
            task.require_dynamic_service 'dyn', :as => 'service_name'
        end
        it "marks the task as needing reconfiguration" do
            flexmock(task).should_receive(:needs_reconfiguration!).once.pass_thru
            task.require_dynamic_service 'dyn', :as => 'service_name'
        end
        it "creates a new dynamic service on the specialized model" do
            bound_service = task.require_dynamic_service 'dyn', :as => 'service_name'
            assert_equal bound_service, task.find_data_service('service_name')
            assert !task_m.find_data_service('service_name')
            assert_same bound_service.model.component_model, task.model
        end
        it "does nothing if requested to create a service that already exists" do
            bound_service = task.require_dynamic_service 'dyn', :as => 'service_name'
            assert_equal bound_service, task.require_dynamic_service('dyn', :as => 'service_name')
        end
        it "raises if requested to instantiate a service without giving it a name" do
            assert_raises(ArgumentError) { task.require_dynamic_service 'dyn' }
        end
        it "raises if requested to instantiate a dynamic service that is not declared" do
            assert_raises(ArgumentError) { task.require_dynamic_service 'nonexistent', :as => 'name' }
        end
        it "raises if requested to instantiate a service that already exists but is not compatible with the dynamic service model" do
            task_m.provides Syskit::DataService.new_submodel, :as => 'srv'
            assert_raises(ArgumentError) { task.require_dynamic_service 'dyn', :as => 'srv' }
        end
        it "supports declaring services as slave devices" do
            master_m = Syskit::Device.new_submodel
            slave_m = Syskit::Device.new_submodel

            task_m.driver_for master_m, :as => 'driver'
            dyn = task_m.dynamic_service slave_m, :as => 'device_dyn' do
                provides slave_m, :as => name, :slave_of => 'driver'
            end
            task = task_m.new
            task.require_dynamic_service 'device_dyn', :as => 'slave'
            assert_equal [task.model.driver_srv], task.model.each_master_driver_service.to_a
        end
    end

    describe "#can_merge?" do
        attr_reader :srv_m, :task_m, :testing_task, :tested_task
        before do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel do
                argument :arg
                dynamic_service srv_m, :as => 'dyn' do
                    provides srv_m.new_submodel, :as => name
                end
            end
            @testing_task, @tested_task = task_m.new, task_m.new
        end

        it "returns true if tasks are of identical models" do
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if the tested task has dynamic services" do
            tested_task.require_dynamic_service 'dyn', :as => 'srv'
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if the testing task has dynamic services" do
            testing_task.require_dynamic_service 'dyn', :as => 'srv'
            assert testing_task.can_merge?(tested_task)
        end
        it "returns true if testing and tested tasks have different dynamic services" do
            tested_task.require_dynamic_service 'dyn', :as => 'srv_1'
            testing_task.require_dynamic_service 'dyn', :as => 'srv_2'
            assert testing_task.can_merge?(tested_task)
        end
        it "returns false if testing and tested tasks have dynamic services with the same name but different models" do
            tested_task.require_dynamic_service 'dyn', :as => 'srv'
            testing_task.require_dynamic_service 'dyn', :as => 'srv'
            assert !testing_task.can_merge?(tested_task)
        end
        it "returns false if the testing task is abstract and the tested task is not" do
            testing_task.abstract = true
            assert !testing_task.can_merge?(tested_task)
        end
        it "returns true if an argument is set on the tested task but not set on the testing task" do
            tested_task.arg = 10
            assert testing_task.can_merge?(tested_task)
        end
    end

    describe "#merge" do
        attr_reader :srv_m, :task_m, :task, :merged_task
        before do
            srv_m = @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel do
                dynamic_service srv_m, :as => 'dyn' do
                    provides (options[:model] || srv_m.new_submodel), :as => name, :slave_of => options[:master]
                end
            end
            @task, @merged_task = task_m.new, task_m.new
            plan.add(task)
            plan.add(merged_task)
        end

        it "does not specialize the receiver if the merged task has no dynamic services" do
            flexmock(task).should_receive(:specialize).never
            task.merge(merged_task)
        end
        it "does not instantiate dynamic services that already exist on the receiver" do
            merged_task.specialize
            merged_task.require_dynamic_service 'dyn', :as => 'srv'
            task.specialize
            flexmock(task.model).should_receive(:find_data_service).with('srv').and_return(true)
            flexmock(task.model).should_receive(:provides_dynamic).never
            task.merge(merged_task)
        end
        it "specializes the receiver if the merged task has dynamic services" do
            merged_task.specialize
            merged_task.require_dynamic_service 'dyn', :as => 'srv'
            flexmock(task).should_receive(:specialize).once.pass_thru
            task.merge(merged_task)
        end
        it "adds dynamic services from the merged task" do
            merged_task.specialize
            merged_task.require_dynamic_service 'dyn', :as => 'srv', :model => (actual_m = srv_m.new_submodel)
            task.specialize
            flexmock(task.model).should_receive(:provides_dynamic).with(actual_m, :as => 'srv', :slave_of => nil).once
            task.merge(merged_task)
        end
        it "adds slave dynamic services as slaves" do
            task_m.provides srv_m, :as => 'master'
            merged_task.specialize
            merged_task.require_dynamic_service 'dyn', :as => 'srv', :model => (actual_m = srv_m.new_submodel), :master => 'master'
            task.specialize
            flexmock(task.model).should_receive(:provides_dynamic).with(actual_m, :as => 'srv', :slave_of => 'master').once
            task.merge(merged_task)
        end
    end

    describe "#deployment_hints" do
        it "should return requirements.deployment_hints if it is not empty" do
            task = Syskit::Component.new
            task.requirements.deployment_hints << Regexp.new("test")
            assert_equal task.requirements.deployment_hints, task.deployment_hints
        end
        it "should return the merged hints from its parents if requirements.deployment_hints is empty" do
            plan.add(task = Syskit::Component.new)
            parents = (1..2).map do
                t = Syskit::Component.new
                t.depends_on task
                t
            end
            flexmock(parents[0]).should_receive(:deployment_hints).once.and_return([1, 2])
            flexmock(parents[1]).should_receive(:deployment_hints).once.and_return([2, 3])
            assert_equal [1, 2, 3].to_set, task.deployment_hints
        end
    end

    describe "#method_missing" do
        it "returns a matching service if called with the #srv_name_srv handler" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_data_service).with('a_service_name').and_return(srv = Object.new)
            assert_same srv, task.a_service_name_srv
        end
        it "raises NoMethodError if called with the #srv_name_srv handler for a service that does not exist" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_data_service).with('a_service_name')
            assert_raises(NoMethodError) { task.a_service_name_srv }
        end
        it "returns a matching port if called with the #port_name_port handler" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_port).with('a_port_name').and_return(obj = Object.new)
            assert_same obj, task.a_port_name_port
        end
        it "raises NoMethodError if called with the #port_name_port handler for a port that does not exist" do
            task = Syskit::Component.new
            flexmock(task).should_receive(:find_port).with('a_port_name')
            assert_raises(NoMethodError) { task.a_port_name_port }
        end
    end

    describe "#should_configure_after" do
        it "adds a configuration precedence link between the given event and the start event of the receiver" do
            plan.add(component = Syskit::Component.new)
            event = Roby::EventGenerator.new
            flexmock(event).should_receive(:add_syskit_configuration_precedence).once.with(component.start_event)
            component.should_configure_after(event)
        end
    end

    describe "#ready_for_setup?" do
        it "returns true on a blank task" do
            Syskit::Component.new.ready_for_setup?
        end
        it "returns false if there are unfullfilled syskit configuration precedence links" do
            plan.add(component = Syskit::Component.new)
            component.should_configure_after(event = Roby::EventGenerator.new)
            assert !component.ready_for_setup?
            component.should_configure_after(Roby::EventGenerator.new)
            event.emit
            assert !component.ready_for_setup?
        end
        it "returns true if all its syskit configuration precedence links are fullfilled" do
            plan.add(component = Syskit::Component.new)
            component.should_configure_after(event = Roby::EventGenerator.new)
            event.emit
            component.should_configure_after(event = Roby::EventGenerator.new)
            event.emit
            assert component.ready_for_setup?
        end
    end

    describe "#commit_transaction" do
        it "specializes the proxied task and applies model modifications if there are some" do
            task_m = Syskit::TaskContext.new_submodel do
                dynamic_output_port /\w+/, nil
            end
            dynport = task_m.orogen_model.dynamic_ports.find { true }

            plan.add(task = task_m.new)
            plan.in_transaction do |trsc|
                proxy = trsc[task]
                proxy.instanciate_dynamic_output_port('name', '/double', dynport)
                trsc.commit_transaction
            end
            assert task.specialized_model?
            assert task.model.find_output_port('name')
        end
    end
end

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


