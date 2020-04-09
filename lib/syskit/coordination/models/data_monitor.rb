# frozen_string_literal: true

module Syskit
    module Coordination
        module Models
            # Representation of a single data monitor
            #
            # Data monitors read some data streams (read: port data readers),
            # feed them into a predicate object that returns a boolean. If the
            # predicate returns true ('triggers'), the monitor will emit a set
            # of events and/or generate a DataMonitoringError Roby exception.
            class DataMonitor
                # @return [String] the monitor name
                attr_reader :name
                # @return [Syskit::Models::OutputReader] the data streams that
                #   are monitored
                attr_reader :data_streams
                # @return [#bind] the predicate model. Its #new method must
                #   return an object that matches the description of
                #   {Coordination::DataMonitor#predicate}
                attr_reader :predicate
                # @return [Boolean] whether instances of this model should
                #   generate a {DataMonitoringError} when it triggers
                # @see {raise}
                attr_predicate :raises?, true
                # @return [Roby::Coordination::Models::Event] the events that
                #   should be emitted when this monitor triggers
                # @see {emit}
                attr_reader :emitted_events

                def initialize(name, data_streams)
                    @name = name
                    @data_streams = data_streams
                    @predicate = nil
                    @emitted_events = []
                    @raises = false
                end

                # Called to generate an object that can be used by a data
                # monitoring table instance
                #
                # @return [Syskit::Coordination::DataMonitor]
                def bind(table)
                    unless predicate
                        raise ArgumentError, "no predicate defined in #{self}"
                    end

                    data_streams = self.data_streams.map do |reader|
                        reader.bind(table.instance_for(reader.port.component_model))
                    end
                    predicate = self.predicate.bind(table, data_streams)
                    monitor = Syskit::Coordination::DataMonitor.new(self, data_streams)
                    monitor.trigger_on(predicate)
                    emitted_events.each do |ev|
                        monitor.emit(table.instance_for(ev))
                    end
                    monitor.raises = raises?
                    monitor
                end

                # Call to make this monitor emit the given event when it
                # triggers
                #
                # @return self
                def emit(event)
                    @emitted_events << event
                    self
                end

                # Call to cause this monitor to generate a DataMonitoringError
                # whenever the predicate triggers
                #
                # @return self
                def raise_exception
                    @raises = true
                    self
                end

                # Defines the predicate that will cause this monitor to trigger
                #
                # @param [#bind] predicate the predicate model object. See
                #   the description of the {predicate} attribute.
                #
                # If a block is given, it is a shortcut to using the
                # DataMonitorPredicateFromBlock. The block will be called with
                # samples from each of the monitor's data sources, and must
                # return true if the monitor should trigger and false otherwise.
                #
                # Both cannot be given.
                #
                # @raise ArgumentError if a predicate is already defined on this
                #   data monitor
                #
                # @return self
                def trigger_on(predicate = nil, &predicate_block)
                    if self.predicate
                        raise ArgumentError, "#{self} already has a trigger, you cannot add another one"
                    elsif predicate && predicate_block
                        raise ArgumentError, "you can give either a predicate object or a predicate block, not both"
                    elsif predicate_block
                        predicate = DataMonitorPredicateFromBlock.new(data_streams, predicate_block)
                    end

                    @predicate = predicate
                    self
                end

                def to_execution_exception_matcher
                    DataMonitoringErrorMatcher.new.from_monitor(self).to_execution_exception_matcher
                end
            end
        end
    end
end
