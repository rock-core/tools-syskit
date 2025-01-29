# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Adapter object to provide Orocos::Async listener API
            #
            # Unlike the disposable returned by the hooks, the listener API
            # from Orocos::Async allows to stop and start listening
            class Listener
                # @param [#call] register_with a callable that will register the callback
                def initialize(register_with)
                    @register_with = register_with
                end

                # Register the callback on the configured object and event
                #
                # Does nothing if the listener is already started
                def start
                    return if @disposable

                    @disposable = @register_with.call
                end

                # De-registers the callback
                #
                # Does nothing if the listener is already started
                def stop
                    @disposable&.dispose
                    @disposable = nil
                end

                def dispose
                    stop
                end
            end
        end
    end
end
