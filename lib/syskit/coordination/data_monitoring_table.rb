module Syskit
    module Coordination
        class DataMonitoringTable < Roby::Coordination::Base
            extend Models::DataMonitoringTable

            # @return [Array<DataMonitor>] list of instanciated data monitors
            attr_reader :monitors

            def initialize(root_task)
                super
                root_task.poll(:on_replace => :drop) do
                    poll
                end
                @monitors = Array.new
                resolve_monitors
            end

            # Instanciates all data monitor registered on this table's models
            # and stores the new monitors in {#monitors}
            def resolve_monitors
                model.each_task do |coordination_task_model|
                    if coordination_task_model.respond_to?(:instanciate)
                        root_task.depends_on(task_instance = coordination_task_model.instanciate(root_task.plan))
                        instance_for(coordination_task_model).bind(task_instance)
                    end
                end

                monitors_m = model.each_monitor.to_a
                model.validate_monitors(monitors_m)
                monitors.concat(monitors_m.map { |m| m.bind(self) })
            end

            # Checks all the monitors for new data, and issue the related errors
            # if their predicate triggers
            def poll
                monitors.each do |m|
                    m.poll(root_task)
                end
            end
        end
    end
end
