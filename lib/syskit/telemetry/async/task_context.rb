# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Definition of hooks for the {TaskContext} class
            #
            # This is made separately to allow overloading them in the main class in
            # a natural way
            class TaskContextHooks
                include Roby::Hooks
                include Roby::Hooks::InstanceHooks

                define_hooks :on_state_change
                define_hooks :on_reachable
                define_hooks :on_unreachable
                define_hooks :on_attribute_reachable
                define_hooks :on_attribute_unreachable
                define_hooks :on_property_reachable
                define_hooks :on_property_unreachable
                define_hooks :on_port_reachable
                define_hooks :on_port_unreachable
            end

            # Callback-based API to the orocos.rb task contexts
            class TaskContext < TaskContextHooks
                # The task context name
                #
                # @return [String]
                attr_reader :name

                # A unique string that allows to identify a remote task
                #
                # @return [String]
                attr_reader :identity

                # The task model
                #
                # @return [OroGen::Spec::TaskContext]
                attr_reader :model

                # Hash code for this task context
                #
                # Two different TaskContext objects that point to the same remote object
                # will be considered the same from the perspective of a hash key
                attr_reader :hash

                def states_index_to_symbols
                    return @states_index_to_symbols if @states_index_to_symbols

                    @states_index_to_symbols = []
                    @states_index_to_symbols[Orocos::TaskContext::STATE_PRE_OPERATIONAL] =
                        :PRE_OPERATIONAL
                    @states_index_to_symbols[Orocos::TaskContext::STATE_STOPPED] =
                        :STOPPED
                    @states_index_to_symbols[Orocos::TaskContext::STATE_RUNNING] =
                        :RUNNING
                    @states_index_to_symbols[Orocos::TaskContext::STATE_RUNTIME_ERROR] =
                        :RUNTIME_ERROR
                    @states_index_to_symbols[Orocos::TaskContext::STATE_EXCEPTION] =
                        :EXCEPTION
                    @states_index_to_symbols[Orocos::TaskContext::STATE_FATAL_ERROR] =
                        :FATAL_ERROR
                    @states_index_to_symbols
                end

                # Discover information about a Orocos::TaskContext and create the
                # corresponding {TaskContext}
                #
                # This is meant to be called in a separate thread
                def self.discover(task, port_read_manager:)
                    async_task = TaskContext.new(
                        task.name, port_read_manager: port_read_manager
                    )

                    # Already do an initial discovery of all the task's interface objects
                    discover_attributes(async_task, task)
                    discover_properties(async_task, task)
                    discover_ports(async_task, task)

                    # We can do this here ONLY BECAUSE we're populating an initial
                    # state. Further updates need to call the `discover_` methods in
                    # the main thread
                    async_task.reachable!(task)
                    async_task
                end

                # @api private
                #
                # Discover a remote task's attributes
                def self.discover_attributes(async_task, task)
                    raw_attributes = task.attribute_names.map { task.attribute(_1) }
                    async_task.discover_attributes(raw_attributes)
                end

                # @api private
                #
                # Discover a remote task's properties
                def self.discover_properties(async_task, task)
                    raw_properties = task.property_names.map { task.property(_1) }
                    async_task.discover_properties(raw_properties)
                end

                # @api private
                #
                # Discover a remote task's ports
                def self.discover_ports(async_task, task)
                    raw_ports = task.port_names.map { task.port(_1) }
                    async_task.discover_ports(raw_ports)
                end

                def initialize(
                    name, port_read_manager:, model: self.class.dummy_orogen_model(name)
                )
                    super()

                    @name = name
                    @model = model
                    # !!!! DO NOT add the identity to the hash code, or it will change
                    # the hash whenever the remote task changes. From the Async
                    # perspective, a task's identity is determined by its name
                    # (we can't have two different tasks with the same name)
                    @hash = name.hash

                    @port_read_manager = port_read_manager
                    @attributes = {}
                    @properties = {}
                    @ports = {}

                    @current_state = nil
                end

                def to_s
                    "TaskContext:#{name}<#{object_id}>"
                end

                @dummy_orogen_models = Concurrent::Hash.new

                def self.dummy_orogen_model(name)
                    @dummy_orogen_models[name] ||=
                        Orocos.create_orogen_task_context_model(name)
                end

                def to_proxy
                    self
                end

                def eql?(other)
                    name == other.name
                end

                # Declare that the remote task is not reachable anymore
                #
                # Must be called from the main thread. It also dispose of the underlying
                # resources
                def unreachable!
                    run_hook :on_unreachable

                    run_interface_unreachable_hooks(
                        @attributes.each_value, :on_attribute_unreachable
                    )
                    run_interface_unreachable_hooks(
                        @properties.each_value, :on_property_unreachable
                    )
                    run_interface_unreachable_hooks(
                        @ports.each_value, :on_port_unreachable
                    )

                    dispose
                end

                def run_interface_unreachable_hooks(objects, event)
                    objects.each do
                        run_hook event, _1.name
                        _1.unreachable!
                    end
                end

                def reachable?
                    @raw_task_context
                end

                # Set the underlying task context
                #
                # Must be called from the main thread
                def reachable!(task_context)
                    @raw_task_context = task_context
                    @identity = task_context.ior

                    run_hook :on_reachable, task_context
                    @state_reader_callback =
                        port("state").on_data(init: true, buffer_size: 20) do |new_state|
                            new_state = states_index_to_symbols[new_state] || new_state
                            @current_state = new_state
                            run_hook :on_state_change, new_state
                        end
                end

                def on_reachable(&block)
                    super

                    block.call if reachable?
                end

                def on_state_change(&block)
                    super

                    # Explicitly ask to send the last received value
                    @port_read_manager.propagate_last_received_value(port("state"))
                end

                def each_attribute(&block)
                    @attributes.each_value(&block)
                end

                def each_property(&block)
                    @properties.each_value(&block)
                end

                def each_port(&block)
                    @ports.each_value(&block)
                end

                def each_input_port(&block)
                    @ports.each_value.find_all(&:input?).each(&block)
                end

                def each_output_port(&block)
                    @ports.each_value.find_all { !_1.input? }.each(&block)
                end

                def on_attribute_reachable(&block)
                    super

                    @attributes.each_key { block.call(_1) }
                end

                def attribute(name)
                    @attributes.fetch(name)
                end

                def on_property_reachable(&block)
                    super

                    @properties.each_key { block.call(_1) }
                end

                def property(name)
                    @properties.fetch(name)
                end

                def on_port_reachable(&block)
                    super

                    @ports.each_key { block.call(_1) }
                end

                def port(name)
                    @ports.fetch(name)
                end

                def discover_attributes(raw_attributes)
                    @attributes =
                        raw_attributes.each_with_object({}) do |p, h|
                            async = Attribute.new(self, p.name, p.type)
                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @attributes.each_value { run_hook :on_attribute_reachable, _1 }
                end

                def discover_properties(raw_properties)
                    @properties =
                        raw_properties.each_with_object({}) do |p, h|
                            async = Property.new(self, p.name, p.type)
                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @properties.each_value { run_hook :on_property_reachable, _1 }
                end

                def discover_ports(raw_ports)
                    @ports =
                        raw_ports.each_with_object({}) do |p, h|
                            async =
                                case p
                                when Orocos::InputPort
                                    InputPort.new(self, p.name, p.type)
                                else
                                    OutputPort.new(
                                        self, p.name, p.type, @port_read_manager
                                    )
                                end

                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @ports.each_value { run_hook :on_port_reachable, _1 }
                end

                def dispose
                    @raw_task_context = nil
                    @current_state = nil

                    @properties.clear
                    @state_reader_callback.dispose
                end
            end
        end
    end
end
