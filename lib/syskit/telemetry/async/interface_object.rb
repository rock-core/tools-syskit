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
                # @return [TaskContext] the underlying task context
                attr_reader :task_context
                # @return [String] the property name
                attr_reader :name
                # @return [Class<Typelib::Type>] the property type
                attr_reader :type

                # Hash code
                #
                # Two interface objects are considered the same from a hash key
                # perspective if they are of the same name, type and point to the
                # same remote task, even if they are two different objects
                attr_reader :hash

                def initialize(task_context, name, type)
                    super()

                    @task_context = task_context
                    @hash = [task_context, self.class, name].hash
                    @name = name
                    @type = type
                end

                def eql?(other)
                    other.task_context.eql?(task_context) &&
                        other.name == name &&
                        other.class == self.class
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
                    disposable = super

                    block.call(@raw_object) if @raw_object
                    disposable
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

                def to_proxy
                    self
                end

                def full_name
                    "#{@task_context.name}.#{@name}"
                end
            end
        end
    end
end
