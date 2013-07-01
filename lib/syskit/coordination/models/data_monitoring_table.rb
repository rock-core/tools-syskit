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
                def monitor(name, *data_streams, &predicate_block)
                    name = name.to_str

                    # Allow giving a data stream as a port
                    data_streams = data_streams.map do |obj|
                        if obj.respond_to?(:reader)
                            obj.reader
                        else obj
                        end
                    end

                    if !data_streams.last.kind_of?(Syskit::Models::OutputReader)
                        predicate = data_streams.pop
                    end
                    if predicate && predicate_block
                        raise ArgumentError, "you can give either a predicate object or a predicate block, not both"
                    elsif predicate_block
                        predicate = DataMonitorPredicateFromBlock.new(data_streams, predicate_block)
                    end

                    monitor = DataMonitor.new(name, data_streams, predicate)
                    monitors << monitor
                    monitor
                end

                def method_missing(m, *args, &block)
                    if m.to_s =~ /(.*)_port$/
                        port_name = $1
                        if port = root.find_port(port_name)
                            if !args.empty?
                                raise ArgumentError, "expected zero arguments to #{m}, got #{args.size}"
                            end
                            return port
                        else raise NoMethodError.new("#{self} has no port called #{port_name}", m)
                        end
                    end
                    return super
                end
            end
        end
    end
end
