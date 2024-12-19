# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Class that defines hooks for {InterfaceObjects}
            #
            # This class is needed so that we can cleanly overload the hook definition
            # methods.
            class InterfaceObjectHooks
                include Roby::Hooks
                include Roby::Hooks::InstanceHooks

                define_hooks :on_reachable
                define_hooks :on_unreachable
                define_hooks :on_data
                define_hooks :on_raw_data
            end

            # Callback-based API to the orocos.rb property API
            class InterfaceObject < InterfaceObjectHooks
                # @return [String] the property name
                attr_reader :name
                # @return [Class<Typelib::Type>] the property type
                attr_reader :type

                def initialize(name, type)
                    super()

                    @name = name
                    @type = type
                end

                def reachable?
                    @raw_object
                end

                # Tie this async property with the underlying direct access object
                def reachable!(raw_object)
                    @raw_object = raw_object
                    run_hook :on_reachable, raw_object
                end

                # Tie this async property with the underlying object
                def unreachable!
                    @raw_object = nil
                    run_hook :on_unreachable
                end

                def on_reachable(&block)
                    super(&block)

                    block.call if @raw_object
                end
            end
        end
    end
end
