module Syskit
    module Coordination
        module Models
            module TaskExtension
                # Returns the data monitoring table that should be added to all
                # instances of this task
                def data_monitoring_table
                    @data_monitoring_table ||= Syskit::Coordination::DataMonitoringTable.new_submodel(model)
                end

                # Add a data monitor on this particular coordination task
                #
                # It will be added to all the instances of this task
                def monitor(name, *data_streams)
                    data_monitoring_table.monitor(name, *data_streams)
                end

                def setup_instanciated_task(coordination_context, task, arguments = Hash.new)
                    data_monitoring_table.new(task, arguments, :on_replace => :copy, :parent => coordination_context)
                    super if defined? super
                end
            end
        end
    end
end
Roby::Coordination::Models::TaskWithDependencies.include Syskit::Coordination::Models::TaskExtension
