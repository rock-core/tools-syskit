# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Definition of hooks related to reading data
            class ReadableInterfaceObjectHooks < InterfaceObject
                define_hooks :on_data
                define_hooks :on_raw_data
            end

            # Base class for interface objects that allow to read data
            class ReadableInterfaceObject < ReadableInterfaceObjectHooks
                # Callback management object with the same API than orocos.rb's
                class Listener
                    def initialize(object, event, block)
                        @object = object
                        @event = event
                        @block = block
                    end

                    def start
                        return if @disposable

                        @disposable = @object.send(@event, &@block)
                    end

                    def listening?
                        @disposable
                    end

                    def stop
                        @disposable&.dispose
                        @disposable = nil
                    end

                    def dispose
                        stop
                    end
                end

                alias __on_raw_data on_raw_data
                def on_raw_data(&block)
                    listener = Listener.new(self, :__on_raw_data, block)
                    listener.start
                    listener
                end

                alias __on_data on_data
                def on_data(&block)
                    listener = Listener.new(self, :__on_data, block)
                    listener.start
                    listener
                end
            end
        end
    end
end
