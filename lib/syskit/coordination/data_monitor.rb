# frozen_string_literal: true

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
            # @return [Array<Roby::Coordination::Event>] the set of events that
            #   should be emitted when this monitor triggers
            attr_reader :emitted_events
            # @return [Boolean] whether this monitor should generate a
            #   {DataMonitoringError} when it triggers
            attr_predicate :raises?, true

            def initialize(model, data_streams)
                @model = model
                @data_streams = data_streams
                @emitted_events = []
                @raises = false
            end

            # Whether the data monitor is attached to all its source streams
            def ready?
                data_streams.all?(&:ready?)
            end

            def trigger_on(predicate)
                @predicate = predicate
                self
            end

            def emit(event)
                @emitted_events << event
                self
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
                    trigger(root_task)
                    true
                else
                    false
                end
            end

            # Issue an error because the predicate returned true (match)
            def trigger(root_task)
                emitted_events.each do |ev|
                    ev = ev.resolve
                    if ev.executable?
                        ev.emit
                    end
                end
                if raises?
                    samples = data_streams.map(&:read)
                    error = DataMonitoringError.new(root_task, self, Time.now, samples)
                    root_task.plan.add_error(error)
                end
            end

            def to_s
                "monitor(#{model.name}(#{data_streams.map(&:to_s).join(', ')})"
            end
        end
    end
end
