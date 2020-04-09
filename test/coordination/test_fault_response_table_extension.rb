# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Coordination::Models::FaultResponseTableExtension do
    it "attaches the associated data monitoring tables to the plan it is attached to" do
        component_m = Syskit::TaskContext.new_submodel
        fault_m = Roby::Coordination::FaultResponseTable.new_submodel
        data_m = Syskit::Coordination::DataMonitoringTable.new_submodel(root: component_m)
        fault_m.use_data_monitoring_table data_m
        flexmock(plan).should_receive(:use_data_monitoring_table).with(data_m, {}).once
        plan.use_fault_response_table fault_m
    end

    it "removes the associated data monitoring tables from the plan when it is removed from it" do
        component_m = Syskit::TaskContext.new_submodel
        fault_m = Roby::Coordination::FaultResponseTable.new_submodel
        data_m = Syskit::Coordination::DataMonitoringTable.new_submodel(root: component_m)
        fault_m.use_data_monitoring_table data_m

        assert plan.data_monitoring_tables.empty?
        fault = plan.use_fault_response_table fault_m
        active_tables = plan.data_monitoring_tables
        assert_equal 1, active_tables.size
        table = active_tables.first
        flexmock(plan).should_receive(:remove_data_monitoring_table).with(table).once.pass_thru
        plan.remove_fault_response_table fault
        assert plan.data_monitoring_tables.empty?
    end

    # Wait for all the data monitoring tables of a given plan to be ready
    def syskit_wait_data_monitoring_ready(plan = self.plan)
        plan.data_monitoring_tables.each do |attached_table|
            attached_table.instances.each do |task, table|
                syskit_wait_ready table, component: task
            end
        end
    end

    it "allows using monitors as fault descriptions" do
        recorder = flexmock
        response_task_m = Roby::Task.new_submodel do
            terminates
        end
        component_m = Syskit::TaskContext.new_submodel(name: "Test") do
            output_port "out1", "/int"
            output_port "out2", "/int"
        end
        table_model = Roby::Coordination::FaultResponseTable.new_submodel do
            data_monitoring_table do
                root component_m
                monitor("threshold", out1_port)
                    .trigger_on do |sample|
                        recorder.called(sample)
                        sample > 10
                    end
                    .raise_exception
            end
            on_fault threshold_monitor do
                locate_on_origin
                response = task(response_task_m)
                execute response
            end
        end

        plan.use_fault_response_table table_model
        assert_equal Array[table_model.data_monitoring_tables.first.table],
                     plan.data_monitoring_tables.map(&:model)
        syskit_stub_configured_deployment(component_m)
        component = syskit_deploy_configure_and_start(component_m)
        ruby_task = component.orocos_task.local_ruby_task
        syskit_wait_data_monitoring_ready

        recorder.should_receive(:called).with(5).once.ordered
        recorder.should_receive(:called).with(11).at_least.once.ordered
        ruby_task.out1.write(5)
        execute_one_cycle
        ruby_task.out1.write(11)

        expect_execution.scheduler(true).to do
            emit find_tasks(response_task_m).start_event
        end
    end

    describe "argument passing" do
        attr_reader :component_m, :data_m, :fault_m

        before do
            @data_m = Syskit::Coordination::DataMonitoringTable.new_submodel
            data_m.argument :arg
            @fault_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_m.argument :test_arg
        end

        it "allows giving static arguments to the used data monitoring tables" do
            fault_m.use_data_monitoring_table data_m, arg: 10
            flexmock(plan).should_receive(:use_data_monitoring_table).once.with(data_m, arg: 10)
            plan.use_fault_response_table fault_m, test_arg: 20
        end

        it "allows passing fault response arguments to the used data monitoring tables" do
            fault_m.use_data_monitoring_table data_m, arg: fault_m.test_arg
            flexmock(plan).should_receive(:use_data_monitoring_table).once.with(data_m, arg: 10)
            plan.use_fault_response_table fault_m, test_arg: 10
        end

        it "allows passing fault response arguments that are also name of arguments on the fault response table" do
            fault_m.use_data_monitoring_table data_m, arg: :test_arg
            flexmock(plan).should_receive(:use_data_monitoring_table).once.with(data_m, arg: :test_arg)
            plan.use_fault_response_table fault_m, test_arg: 10
        end

        it "raises if the embedded data monitoring table requires arguments that do not exist on the fault response table" do
            assert_raises(ArgumentError) do
                Roby::Coordination::FaultResponseTable.new_submodel do
                    data_monitoring_table { argument :bla }
                end
            end
        end

        it "allows the embedded data monitoring table to have optional arguments" do
            fault_m = Roby::Coordination::FaultResponseTable.new_submodel do
                data_monitoring_table do
                    argument :arg, default: 10
                end
            end
            flexmock(plan).should_receive(:use_data_monitoring_table).once.with(fault_m.data_monitoring_table, {})
            plan.use_fault_response_table fault_m
        end
        it "allows used data monitoring tables to have optional arguments" do
            data_m = Syskit::Coordination::DataMonitoringTable.new_submodel
            data_m.argument :arg, default: 10
            fault_m = Roby::Coordination::FaultResponseTable.new_submodel
            fault_m.use_data_monitoring_table data_m
            flexmock(plan).should_receive(:use_data_monitoring_table).once.with(data_m, {})
            plan.use_fault_response_table fault_m
        end
    end
end
