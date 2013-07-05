module Syskit
    module Coordination
        module Models
            class InvalidDataMonitor < StandardError
                # @return [DataMonitor] the invalid monitor
                attr_reader :monitor
            end

            module DataMonitoringTable
                include Roby::Coordination::Models::Base

                # @return [Array<DataMonitor>] the set of data monitoring
                #   objects that are defined on this table
                inherited_attribute(:monitor, :monitors) { Array.new }

                # Define a new data monitor
                #
                # @overload monitor(:low_battery, battery_status_port) { |level| # level < 1 }
                #   Calls the provided block each time a new sample is available
                #   on the given port. The monitor will trigger (i.e. raise a
                #   DataMonitoringError) when the predicate returns true
                #
                # @return [DataMonitor] the new data monitor model
                def monitor(name, *data_streams)
                    name = name.to_str

                    # Allow giving a data stream as a port
                    data_streams = data_streams.map do |obj|
                        if obj.respond_to?(:reader)
                            obj.reader
                        elsif obj.respond_to?(:port)
                            obj
                        else raise ArgumentError, "#{obj} does not seem to be a valid data source. Expected a port or a data reader"
                        end
                    end

                    monitor = DataMonitor.new(name, data_streams)
                    monitors << monitor
                    monitor
                end

                def apply_block(&block)
                    super
                    validate_monitors(monitors)
                end

                # Validate that the given monitors are proper definitions (i.e.
                # that all their required parameters are set)
                #
                # @raise InvalidDataMonitor
                def validate_monitors(monitors)
                    monitors.each do |m|
                        if !m.predicate
                            raise InvalidDataMonitor.new(m), "#{m} has no associated predicate"
                        elsif m.emitted_events.empty? && !m.raises?
                            raise InvalidDataMonitor.new(m), "#{m} has no effect (it neither emits events nor generates an exception). You must either call #emit or #raise_exception on it"
                        end
                    end
                end
                def method_missing(m, *args, &block)
                    MetaRuby::DSLs.find_through_method_missing(root, m, args, "port") ||
                        super
                end
            end
        end
    end
end
