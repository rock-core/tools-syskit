require 'syskit/test'

describe Syskit::Coordination::PlanExtension do
    include Syskit::SelfTest
    it "will attach a data monitoring table to the instances of objects it applies to" do
        component_m = Syskit::TaskContext.new_submodel
        table = Syskit::Coordination::DataMonitoringTable.new_submodel(component_m)
        plan.use_data_monitoring_table table

        task = component_m.new
        flexmock(table).should_receive(:new).with(task).once
        plan.add(task)
    end
end
