# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
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
                    puts "#{Time.now} #{task.name}: created state reader"
                    raw_attributes = task.attribute_names.map { task.attribute(_1) }
                    puts "#{Time.now} #{task.name}: created attributes"
                    raw_properties = task.property_names.map { task.property(_1) }
                    puts "#{Time.now} #{task.name}: created properties"
                    raw_ports = task.port_names.map { task.port(_1) }
                    puts "#{Time.now} #{task.name}: created ports"

                    # We can do this here ONLY BECAUSE we're populating an initial
                    # state. Further updates need to call the `discover_` methods in
                    # the main thread
                    async_task.reachable!(task, state_reader: state_reader)
                    async_task.discover_attributes(raw_attributes)
                    async_task.discover_properties(raw_properties)
                    async_task.discover_ports(raw_ports)
                    puts "#{Time.now} #{task.name}: discovered"
                    async_task
                end

                def initialize(name)
                    @name = name

                    @attributes = {}
                    @properties = {}
                    @ports = {}

                    @current_state = nil
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

                    @attributes.each_value do
                        run_hook :on_attribute_unreachable, _1
                        _1.unreachable!
                    end

                    @properties.each_value do
                        run_hook :on_property_unreachable, _1
                        _1.unreachable!
                    end

                    @ports.each_value do
                        run_hook :on_port_unreachable, _1
                        _1.unreachable!
                    end

                    dispose
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

                def each_property(&block)
                    @properties.each_value(&block)
                end

                def on_attribute_reachable(&block)
                    super

                    @attributes.each_value { block.call(_1) }
                end

                def on_property_reachable(&block)
                    super

                    @properties.each_value { block.call(_1) }
                end

                def on_port_reachable(&block)
                    super

                    @ports.each_value { block.call(_1) }
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
                            async = Port.new(p.name, p.type)
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
                    begin
                        while (new_state = read_new_state)
                            @current_state = new_state
                            run_hook :on_state_change, new_state
                        end
                    rescue ThreadError
                        sleep(period)
                    end
                end

                def read_new_state
                    @state_read_queue.pop(true)
                rescue ThreadError
                end
            end
        end
    end
end
