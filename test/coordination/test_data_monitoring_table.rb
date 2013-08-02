require 'syskit/test'

describe Syskit::Coordination::DataMonitoringTable do
    include Syskit::SelfTest

    it "generates an error if one of its monitor has no trigger" do
        component_m = Syskit::TaskContext.new_submodel { output_port 'out', '/int' }
        table_m = Syskit::Coordination::DataMonitoringTable.new_submodel(:root => component_m)
        table_m.monitor('sample_value_10', table_m.out_port)
        root_task = syskit_deploy_and_start_task_context(component_m, 'task')
        assert_raises(Syskit::Coordination::Models::InvalidDataMonitor) { table_m.new(root_task) }
    end

    it "generates an error if one of its monitor has no effect" do
        component_m = Syskit::TaskContext.new_submodel { output_port 'out', '/int' }
        table_m = Syskit::Coordination::DataMonitoringTable.new_submodel(:root => component_m)
        table_m.monitor('sample_value_10', table_m.out_port).
            trigger_on { |sample| }
        root_task = syskit_deploy_and_start_task_context(component_m, 'task')
        assert_raises(Syskit::Coordination::Models::InvalidDataMonitor) { table_m.new(root_task) }
    end

    it "should raise if some monitors have no effect at the end of the definition block" do
        component_m = Syskit::TaskContext.new_submodel { output_port 'out', '/int' }
        assert_raises(Syskit::Coordination::Models::InvalidDataMonitor) do
            Syskit::Coordination::DataMonitoringTable.new_submodel(:root => component_m) do
                monitor 'test', out_port do
                end
            end
        end
    end

    it "generates a CodeError if the trigger raises" do
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        recorder = flexmock
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => component_m)
        table_model.monitor('test', table_model.out_port).
            trigger_on { |sample| raise }.
            raise_exception

        component = syskit_deploy_task_context(component_m, 'task')
        table = table_model.new(component)
        syskit_start_component(component)
        component.orocos_task.out.write(10)
        inhibit_fatal_messages do
            process_events
        end
        assert_kind_of Roby::CodeError, component.failure_reason
    end

    it "gives access to the monitoring table arguments as local variables in the blocks" do
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        recorder = flexmock
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => component_m)
        table_model.argument :arg
        table_model.monitor('test', table_model.out_port).
            trigger_on do |sample|
                recorder.called(arg)
                false
            end.raise_exception

        component = syskit_deploy_task_context(component_m, 'task')
        table = table_model.new(component, :arg => 10)
        recorder.should_receive(:called).with(10).at_least.once
        syskit_start_component(component)
        component.orocos_task.out.write(20)
        process_events
    end

    it "allows to store state using local variables" do
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        recorder = flexmock
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => component_m)
        table_model.argument :arg
        table_model.monitor('test', table_model.out_port).
            trigger_on do |sample|
                @value = !@value
                recorder.called(@value)
                false
            end.raise_exception

        component = syskit_deploy_task_context(component_m, 'task')
        table = table_model.new(component, :arg => 10)
        recorder.should_receive(:called).with(true).at_least.once
        recorder.should_receive(:called).with(false).at_least.once
        syskit_start_component(component)
        component.orocos_task.out.write(20)
        process_events
        component.orocos_task.out.write(20)
        process_events
    end

    it "can attach to a component and trigger an error when the condition is met" do
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out1', '/int'
            output_port 'out2', '/int'
        end
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => component_m)
        recorder = flexmock
        table_model.monitor('sample_value_10', table_model.out1_port, table_model.out2_port).
            trigger_on do |sample1, sample2|
                recorder.called(sample1, sample2)
                sample1 + sample2 > 10
            end.
            emit(table_model.success_event).
            raise_exception

        recorder.should_receive(:called).with(5, 2).once.ordered
        recorder.should_receive(:called).with(5, 7).once.ordered

        component = syskit_deploy_and_start_task_context(component_m, 'task')
        table = table_model.new(component)
        process_events
        component.orocos_task.out1.write(5)
        component.orocos_task.out2.write(2)
        table.poll
        component.orocos_task.out2.write(7)
        assert_raises(Syskit::Coordination::DataMonitoringError) do
            inhibit_fatal_messages do
                table.poll
            end
        end
        assert component.success?
    end
    it "can monitor the child of a composition, and applies port mappings" do
        srv_m = Syskit::DataService.new_submodel(:name => 'Srv') { output_port 'out', '/int' }
        composition_m = Syskit::Composition.new_submodel(:name => 'Cmp') { add srv_m, :as => 'test' }
        component_m = Syskit::TaskContext.new_submodel(:name => 'Task') do
            output_port 'out1', '/int'
            output_port 'out2', '/int'
            provides srv_m, :as => 'test1', 'out' => 'out1'
            provides srv_m, :as => 'test2', 'out' => 'out2'
        end
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => composition_m)
        recorder = flexmock
        table_model.monitor('sample_value_10', table_model.test_child.out_port).
            raise_exception.
            emit(table_model.test_child.success_event).
            trigger_on do |sample|
                recorder.called(sample)
                sample > 10
            end

        recorder.should_receive(:called).with(2).once.ordered
        recorder.should_receive(:called).with(12).once.ordered

        component = syskit_deploy_and_start_task_context(component_m, 'task')
        composition = composition_m.use('test' => component.test2_srv).instanciate(plan)
        composition.depends_on composition.test_child, :success => :success, :remove_when_done => false
        plan.add_permanent(composition)

        table = table_model.new(composition)
        process_events
        component = composition.test_child
        component.orocos_task.out1.write(2)
        component.orocos_task.out2.write(2)
        table.poll
        component.orocos_task.out1.write(1)
        component.orocos_task.out2.write(12)
        assert_raises(Syskit::Coordination::DataMonitoringError) do
            inhibit_fatal_messages do
                table.poll
            end
        end
        assert component.success?
    end

    it "can use whole component networks as data sources" do
        srv_m = Syskit::DataService.new_submodel(:name => 'Srv') { output_port 'out', '/int' }
        composition_m = Syskit::Composition.new_submodel(:name => 'Cmp') do
            add srv_m, :as => 'test'
            export test_child.out_port
        end
        component_m = Syskit::TaskContext.new_submodel(:name => 'Task') do
            output_port 'out1', '/int'
            output_port 'out2', '/int'
            provides srv_m, :as => 'test1', 'out' => 'out1'
            provides srv_m, :as => 'test2', 'out' => 'out2'
        end
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(:root => composition_m)
        recorder = flexmock
        monitor_task = table_model.task(composition_m.use('test' => component_m.test2_srv))
        table_model.monitor('sample_value_10', table_model.out_port, monitor_task.out_port).
            trigger_on do |sample1, sample2|
                recorder.called(sample1, sample2)
                sample1 + sample2 > 10
            end.
            emit(table_model.success_event).
            raise_exception

        recorder.should_receive(:called).with(4, 2).once.ordered
        recorder.should_receive(:called).with(1, 12).once.ordered

        component = syskit_deploy_task_context(component_m)
        plan.add_permanent(composition = composition_m.use('test' => component.test1_srv).instanciate(plan))
        syskit_start_component(composition)
        table = table_model.new(composition)
        process_events
        Syskit::Runtime.apply_requirement_modifications(plan)

        monitor     = (plan.find_tasks(composition_m).to_a - [composition]).first
        # We want the fault table to emit 'success', don't make it an error
        composition.depends_on composition.test_child,
            :success => :success, :remove_when_done => false

        component = composition.test_child
        component.orocos_task.out1.write(4)
        component.orocos_task.out2.write(2)
        table.poll
        component.orocos_task.out1.write(1)
        component.orocos_task.out2.write(12)
        assert_raises(Syskit::Coordination::DataMonitoringError) do
            inhibit_fatal_messages do
                table.poll
            end
        end
        assert composition.success?
    end
end

