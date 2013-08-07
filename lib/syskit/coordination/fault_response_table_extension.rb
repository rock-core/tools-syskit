module Syskit
    module Coordination
        module FaultResponseTableExtension
            def attach_to(plan)
                super
                model.each_data_monitoring_table do |tbl|
                    data_args = tbl.arguments.map_value do |data_arg, fault_arg|
                        if fault_arg.kind_of?(Roby::Coordination::Models::Variable)
                            arguments[fault_arg.name]
                        else fault_arg
                        end
                    end
                    plan.use_data_monitoring_table tbl.table, data_args
                end
            end

        end
    end
end
Roby::Coordination::FaultResponseTable.include Syskit::Coordination::FaultResponseTableExtension
