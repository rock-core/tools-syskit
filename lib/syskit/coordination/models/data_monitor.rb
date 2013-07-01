module Syskit
    module Coordination
        module Models
            # Representation of a single data monitor
            class DataMonitor
                # @return [String] the monitor name
                attr_reader :name
                # @return [Syskit::Models::OutputReader] the data streams that
                #   are monitored
                attr_reader :data_streams
                # @return [#new] the predicate model. Its #new method must
                #   return an object that matches the description of
                #   {Coordination::DataMonitor#predicate}
                attr_reader :predicate

                def initialize(name, data_streams, predicate)
                    @name, @data_streams, @predicate = name, data_streams, predicate
                end

                def new(table)
                    data_streams = self.data_streams.map do |reader|
                        reader.bind(table.instance_for(reader.port.component_model))
                    end
                    predicate = self.predicate.new(data_streams)
                    Syskit::Coordination::DataMonitor.new(self, data_streams, predicate)
                end
            end
        end
    end
end

