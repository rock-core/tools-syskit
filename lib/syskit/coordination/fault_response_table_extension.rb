module Syskit
    module Coordination
        module FaultResponseTableExtension
            def attach_to(plan)
                super
                model.each_data_monitoring_table do |tbl|
                    plan.use_data_monitoring_table tbl
                end
            end

        end
    end
end
Roby::Coordination::FaultResponseTable.include Syskit::Coordination::FaultResponseTableExtension
