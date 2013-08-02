require 'syskit/test'

describe Syskit::Coordination::Models::FaultResponseTableExtension do
    include Syskit::SelfTest

    it "should attach the associated data monitoring tables to the plan it is attached to" do
        component_m = Syskit::TaskContext.new_submodel
        fault_m = Roby::Coordination::FaultResponseTable.new_submodel
        data_m = Syskit::Coordination::DataMonitoringTable.new_submodel(:root => component_m)
        fault_m.use_data_monitoring_table data_m
        flexmock(plan).should_receive(:use_data_monitoring_table).with(data_m, Hash.new).once
        plan.use_fault_response_table fault_m
    end

    it "should allow using monitors as fault descriptions, and properly set them up at runtime" do
        recorder = flexmock
        response_task_m = Roby::Task.new_submodel do
            terminates
        end
        component_m = Syskit::TaskContext.new_submodel(:name => 'Test') do
            output_port 'out1', '/int'
            output_port 'out2', '/int'
        end
        table_model = Roby::Coordination::FaultResponseTable.new_submodel do
            data_monitoring_table do
                root component_m
                monitor("threshold", out1_port).
                    trigger_on do |sample|
                        recorder.called(sample)
                        sample > 10
                    end.
                    raise_exception
            end
            on_fault threshold_monitor do
                locate_on_origin
                response = task(response_task_m)
                execute response
            end
        end

        plan.use_fault_response_table table_model
        assert_equal Hash[table_model.data_monitoring_tables.first.table => []],
            plan.data_monitoring_tables
        stub_syskit_deployment_model(component_m)
        component = deploy(component_m)
        syskit_start_component(component)
        process_events
        process_events

        recorder.should_receive(:called).with(5).once.ordered
        recorder.should_receive(:called).with(11).once.ordered
        component.orocos_task.out1.write(5)
        process_events
        component.orocos_task.out1.write(11)
        process_events

        assert(response_task = plan.find_tasks(response_task_m).running.first)
    end

    it "should allow passing arguments to the used data monitoring tables" do
        recorder = flexmock
        component_m = Syskit::TaskContext.new_submodel do
            output_port 'out', '/int'
        end
        data_m = Syskit::Coordination::DataMonitoringTable.new_submodel do
            root component_m
            argument :arg
            monitor('test', out_port).
                trigger_on do |value|
                    recorder.called(arg)
                    false
                end.
                raise_exception
        end
        fault_m = Roby::Coordination::FaultResponseTable.new_submodel do
            argument :test_arg
            use_data_monitoring_table data_m, :arg => test_arg
        end

        recorder.should_receive(:called).with(10).at_least.once
        plan.use_fault_response_table fault_m, :test_arg => 10
        component = syskit_deploy_and_start_task_context(component_m)
        process_events
        process_events
        component.orocos_task.out.write(10)
        process_events
    end

    it "should raise if the embedded data monitoring table requires arguments that do not exist on the fault response table" do
        assert_raises(ArgumentError) do
            Roby::Coordination::FaultResponseTable.new_submodel do
                data_monitoring_table { argument :bla }
            end
        end
    end

    it "should allow having optional arguments embedded data monitoring table requires arguments without a corresponding one on the fault response table" do
        Roby::Coordination::FaultResponseTable.new_submodel do
            data_monitoring_table { argument :bla, :default => 10 }
        end
    end
end
