# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Coordination::PlanExtension do
    it "will attach a data monitoring table to the instances of objects it applies to" do
        component_m = Syskit::TaskContext.new_submodel
        table = Syskit::Coordination::DataMonitoringTable.new_submodel(root: component_m)
        plan.use_data_monitoring_table table

        task = component_m.new
        flexmock(table).should_receive(:new).with(task, {}).once
        plan.add(task)
    end
end
