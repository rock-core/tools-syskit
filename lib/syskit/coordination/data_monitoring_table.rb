module Syskit
    module Coordination
        class DataMonitoringTable < Roby::Coordination::Base
            extend Models::DataMonitoringTable

            # @return [Array<DataMonitor>] list of instanciated data monitors
            attr_reader :monitors

            def initialize(root_task)
                super
                @monitors = Array.new
                resolve_monitors
            end

            # Instanciates all data monitor registered on this table's models
            # and stores the new monitors in {#monitors}
            def resolve_monitors
                model.each_monitor do |m|
                    if m.emitted_events.empty? && !m.raises?
                        raise ArgumentError, "#{m} has no effect (it neither emits events nor generates an exception). You must either call #emit or #raise_exception on it"
                    end
                    monitors << m.bind(self)
                end
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
