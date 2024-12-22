# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Callback-based API for remote task ports
            class Attribute < ReadableInterfaceObject
                def on_raw_change(&block)
                    on_raw_data(&block)
                end

                def on_change(&block)
                    on_data(&block)
                end
            end
        end
    end
end
