module Syskit
    module Coordination
        module FaultResponseTableExtension
            # @return [Array<Object>] array of data monitoring table IDs, as
            #   returned by PlanExtension#use_data_monitoring_table
            attr_reader :data_monitoring_tables

            # Hook called when the table is removed from the plan
            #
            # @see Roby::Coordination::FaultResponseTable#removed!
            def removed!
                super if defined? super
                data_monitoring_tables.each do |tbl|
                    plan.remove_data_monitoring_table(tbl)
                end
            end

            # Hook called when the table is attached on the plan
            #
            # @see Roby::Coordination::Actions#attach_to
            def attach_to(plan)
                super if defined? super

                @data_monitoring_tables = Array.new
                model.each_data_monitoring_table do |tbl|
                    data_args = tbl.arguments.map_value do |data_arg, fault_arg|
                        if fault_arg.kind_of?(Roby::Coordination::Models::Variable)
                            arguments[fault_arg.name]
                        else fault_arg
                        end
                    end
                    data_monitoring_tables << plan.use_data_monitoring_table(tbl.table, data_args)
                end
            end
        end
    end
end
Roby::Coordination::FaultResponseTable.class_eval do
    prepend Syskit::Coordination::FaultResponseTableExtension
end
