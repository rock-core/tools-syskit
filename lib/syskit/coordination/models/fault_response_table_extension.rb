module Syskit
    module Coordination
        module Models
            # Module providing the methods necessary to easily use the data
            # monitoring tables within a fault response table
            module FaultResponseTableExtension
                extend MetaRuby::Attributes

                inherited_attribute(:data_monitoring_table, :data_monitoring_tables) { Array.new }

                def data_monitoring(model, &block)
                    table = Syskit::Coordination::DataMonitoringTable.new_submodel(model)
                    table.apply_block(&block)
                    use_data_monitoring_table table
                    table
                end

                def use_data_monitoring_table(table)
                    data_monitoring_tables << table
                end

                def find_monitor(name)
                    each_data_monitoring_table do |tbl|
                        if m = tbl.find_monitor(name)
                            return m
                        end
                    end
                    nil
                end

                def method_missing(m, *args, &block)
                    MetaRuby::DSLs.find_through_method_missing(self, m, args, "monitor") ||
                        super
                end
            end
        end
    end
end

Roby::Coordination::FaultResponseTable.extend Syskit::Coordination::Models::FaultResponseTableExtension
