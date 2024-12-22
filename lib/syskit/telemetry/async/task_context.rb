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

                # Discover information about a Orocos::TaskContext and create the
                # corresponding {TaskContext}
                #
                # This is meant to be called in a separate thread
                def self.discover(task)
                    async_task = TaskContext.new(task.name)

                    # Already do an initial discovery of all the task's interface objects
                    state_reader = task.state_reader(
                        pull: true, type: :circular_buffer, size: 10
                    )
                    discover_attributes(async_task, task)
                    discover_properties(async_task, task)
                    discover_ports(async_task, task)

                    # We can do this here ONLY BECAUSE we're populating an initial
                    # state. Further updates need to call the `discover_` methods in
                    # the main thread
                    async_task.reachable!(task, state_reader: state_reader)
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

                def initialize(name, model: self.class.dummy_orogen_model(name))
                    super()

                    @name = name
                    @model = model

                    @attributes = {}
                    @properties = {}
                    @ports = {}

                    @current_state = nil
                end

                @dummy_orogen_models = Concurrent::Hash.new

                def self.dummy_orogen_model(name)
                    @dummy_orogen_models[name] ||=
                        Orocos.create_orogen_task_context_model(name)
                end

                def to_proxy
                    self
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
                def reachable!(task_context, state_reader:)
                    @raw_task_context = task_context
                    @identity = task_context.ior
                    state_read_init(state_reader)
                    run_hook :on_reachable, task_context
                end

                def on_reachable(&block)
                    super

                    block.call if reachable?
                end

                def state_read_init(state_reader)
                    @state_reader = state_reader

                    @state_read_queue = queue = Queue.new
                    @state_read_stop = event = Concurrent::Event.new
                    @state_read_thread = Thread.new do
                        state_read_poll_thread(state_reader, queue, event)
                    end
                end

                def on_state_change(&block)
                    super

                    block.call(@current_state) if @current_state
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
                            async = Attribute.new(p.name, p.type)
                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @attributes.each_value { run_hook :on_attribute_reachable, _1 }
                end

                def discover_properties(raw_properties)
                    @properties =
                        raw_properties.each_with_object({}) do |p, h|
                            async = Property.new(p.name, p.type)
                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @properties.each_value { run_hook :on_property_reachable, _1 }
                end

                def discover_ports(raw_ports)
                    @ports =
                        raw_ports.each_with_object({}) do |p, h|
                            klass =
                                case p
                                when Orocos::InputPort
                                    InputPort
                                else
                                    OutputPort
                                end

                            async = klass.new(p.name, p.type)
                            async.reachable!(p)
                            h[p.name] = async
                        end

                    @ports.each_value { run_hook :on_port_reachable, _1 }
                end

                def dispose
                    @raw_task_context = nil

                    Concurrent::Promises.future(@state_reader, &:disconnect)
                    @properties.clear
                end

                def state_read_poll_thread(reader, queue, stop, period: 0.1)
                    until stop.set?
                        tic = Time.now
                        while (state = reader.read_new)
                            queue << state
                        end
                        remaining = period - (Time.now - tic)
                        sleep remaining if remaining > 0.01
                    end
                end

                def poll(period: 0.1)
                    while (new_state = read_new_state)
                        @current_state = new_state
                        run_hook :on_state_change, new_state
                    end
                rescue ThreadError
                    sleep(period)
                end

                def read_new_state
                    @state_read_queue.pop(true)
                rescue ThreadError # rubocop:disable Lint/SuppressedException
                end
            end
        end
    end
end
