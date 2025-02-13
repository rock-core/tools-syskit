# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Async interface compatible with the orocos.rb's API
            class InputPort < ReadableInterfaceObject
                def output?
                    false
                end

                def input?
                    true
                end
            end
        end
    end
end
