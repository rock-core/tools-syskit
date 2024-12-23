# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Async interface compatible with the orocos.rb's API
            class OutputPort < ReadableInterfaceObject
                def output?
                    true
                end

                def input?
                    false
                end

                # Asynchronously create a data reader on this port
                def reader(connect_on:, disconnect_on:, **policy)
                    OutputReader.new(
                        self, policy,
                        connect_on: connect_on, disconnect_on: disconnect_on
                    )
                end
            end
        end
    end
end
