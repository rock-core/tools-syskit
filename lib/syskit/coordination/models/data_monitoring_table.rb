module Syskit
    module Coordination
        module Models
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
                        else obj
                        end
                    end

                    monitor = DataMonitor.new(name, data_streams)
                    monitors << monitor
                    monitor
                end

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
