module Syskit
    module Coordination
        # A {Models::DataMonitor} instanciated for a data monitor table attached
        # to an actual component
        class DataMonitor
            # @return [Models::DataMonitor] the monitor model
            attr_reader :model
            # @return [Syskit::OutputReader] the data streams that
            #   are monitored
            attr_reader :data_streams
            # @return [#call,#finalize] the predicate. It will be called each
            #   time there is a new sample on one of the data streams with the
            #   data stream that got a new sample as well as the sample itself.
            #   In addition, #finalize is called at the end of a data gathering
            #   cycle, i.e. after #call has been called with all new samples. It
            #   must return whether the predicate matches (true) or not (false)
            attr_reader :predicate

            def initialize(model, data_streams, predicate)
                @model, @data_streams, @predicate = model, data_streams, predicate
            end

            # Reads the data streams, and pushes the data to the predicate when
            # applicable
            def poll(root_task)
                data_streams.each do |reader|
                    while sample = reader.read_new
                        predicate.call(reader, sample)
                    end
                end
                if predicate.finalize
                    issue_monitoring_error(root_task)
                    true
                else
                    false
                end
            end

            # Issue an error because the predicate returned true (match)
            def issue_monitoring_error(root_task)
                samples = data_streams.map do |reader|
                    reader.read
                end
                root_task.plan.add_error(DataMonitoringError.new(root_task, self, Time.now, samples))
            end

            def to_s; "monitor(#{model.name}(#{data_streams.map(&:to_s).join(", ")})" end
        end
    end
end
