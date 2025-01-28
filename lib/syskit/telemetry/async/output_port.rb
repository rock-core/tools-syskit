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
            end
        end
    end
end
