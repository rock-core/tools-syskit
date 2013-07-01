require 'syskit/test'

describe Syskit::Coordination::DataMonitor do
    include Syskit::SelfTest

    it "can attach to a component and trigger an error when the condition is met" do
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out1', '/int'
            output_port 'out2', '/int'
        end
        table_model = Syskit::Coordination::DataMonitoringTable.
            new_submodel(component_m)
        recorder = flexmock
        table_model.monitor('sample_value_10', table_model.out1_port, table_model.out2_port) do |sample1, sample2|
            recorder.called(sample1, sample2)
            sample1 + sample2 > 10
        end

        recorder.should_receive(:called).with(5, 2).once.ordered
        recorder.should_receive(:called).with(5, 7).once.ordered

        plan.add(component = deploy_and_start_task_context('task', component_m))
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
            new_submodel(composition_m)
        recorder = flexmock
        table_model.monitor('sample_value_10', table_model.test_child.out_port) do |sample|
            recorder.called(sample)
            sample > 10
        end

        recorder.should_receive(:called).with(2).once.ordered
        recorder.should_receive(:called).with(12).once.ordered

        composition = composition_m.use('test' => component_m.test2_srv).instanciate(plan)
        plan.add_permanent(composition)
        deploy_and_start_task_context('task', composition.test_child)

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
    end
end

