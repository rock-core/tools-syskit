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
                define_hooks :on_error
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
                    super

                    block.call if @raw_object
                end

                def once_on_reachable(&block)
                    # on_reachable might call the block right away, in which case
                    # `listener` will be nil. Use the called flag to allow disposing
                    # of the listener the second time without causing a double call
                    # to the block
                    called = false
                    listener = on_reachable do
                        block.call unless called
                        called = true
                        listener&.dispose
                    end
                end

                def new_sample
                    @type.zero
                end

                def type_name
                    @type.name
                end
            end
        end
    end
end
