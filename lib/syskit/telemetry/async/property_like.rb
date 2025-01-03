# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Callback-based API to listen to changes for property-like interface objects
            # (attributes and properties)
            class PropertyLike < InterfaceObject
                def initialize(task_context, name, type, manager)
                    super(task_context, name, type)

                    @manager = manager
                end

                def on_raw_change(&block)
                    callback = proc(&block)

                    register_with = proc do
                        @manager.register_callback(self, callback)
                    end

                    listener = Listener.new(register_with)
                    listener.start
                    listener
                end

                def on_change
                    on_raw_change do |data|
                        yield Typelib.to_ruby(data)
                    end
                end
            end
        end
    end
end
