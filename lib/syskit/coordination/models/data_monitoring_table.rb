# frozen_string_literal: true

module Syskit
    module Coordination
        module Models
            class InvalidDataMonitor < StandardError
                # @return [DataMonitor] the invalid monitor
                attr_reader :monitor
            end

            # Model-level API for data monitoring tables
            #
            # @see Syskit::Coordination::DataMonitoringTable
            module DataMonitoringTable
                include Roby::Coordination::Models::Base

                # @return [Array<#===>] set of Roby task matchers that describe
                #   where this data monitor should be attached. They must
                #   obviously match the table's root task model
                #
                # @see {attach_to}
                inherited_attribute(:attachment_point, :attachment_points) { [] }

                # @return [Array<DataMonitor>] the set of data monitoring
                #   objects that are defined on this table
                inherited_attribute(:monitor, :monitors) { [] }

                # Define a new data monitor
                #
                # Data monitors are objects that watch some data streams and
                # either emit events and/or raise exceptions
                #
                # @example Register a block and emit an event when it returns true
                #   monitor(:low_battery, battery_status_port).
                #       trigger_on { |level| # level < 1 }.
                #       emit battery_low_event
                #
                # @example Register a block and generate a DataMonitoringError when it returns true
                #   monitor(:low_battery, battery_status_port).
                #       trigger_on { |level| # level < 1 }.
                #       raise_exception
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

                def find_monitor(name)
                    each_monitor do |m|
                        return m if m.name == name
                    end
                    nil
                end

                # Declares that this table should be attached to the tasks
                # matching the given query
                #
                # If none is defined, it is going to be attached to every
                # instance of the root model (i.e. the table's root task model)
                #
                # @param [#===] query object used to match tasks in the Roby
                #   plan. It must obviously match subclasses of the table's root
                #   task model
                def attach_to(query)
                    attachment_points << query
                end

                def has_through_method_missing?(m)
                    MetaRuby::DSLs.has_through_method_missing?(
                        root, m, "_port" => :has_port?
                    ) || super
                end

                def find_through_method_missing(m, args)
                    MetaRuby::DSLs.find_through_method_missing(
                        root, m, args, "_port" => :find_port
                    ) || super
                end

                include MetaRuby::DSLs::FindThroughMethodMissing
            end
        end
    end
end
