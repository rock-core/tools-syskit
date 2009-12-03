module Orocos
    module RobyPlugin
        class Robot
            def initialize(engine)
                @engine     = engine
                @com_busses = Hash.new
                @devices    = Hash.new
            end

            # The underlying engine
            attr_reader :engine
            # The available communication busses
            attr_reader :com_busses
            # The devices that are available on this robot
            attr_reader :devices

            def com_bus(name)
                com_busses[name] = CommunicationBus.new(self, name)
            end

            def through(com_bus, &block)
                bus = com_busses[com_bus]
                if !bus
                    raise SpecError, "communication bus #{com_bus} does not exist"
                end
                bus.through(&block)
                bus
            end

            def device(name, options = Hash.new)
                options, device_options = Kernel.filter_options options, :type => name
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                device_type  = options[:type]
                if !(device_model = Roby.app.orocos_devices[device_type])
                    raise ArgumentError, "unknown device type '#{device_type}'"
                end

                devices[name] = device_model.task_model.instanciate(engine.plan, {:device_name => name}.merge(device_options))
            end
        end

        class Engine
            # The plan we are working on
            attr_reader :plan
            # The model we are taking our tasks from
            attr_reader :model
            # The robot on which the software is running
            attr_reader :robot
            # The instances we are supposed to build
            attr_reader :instances
            # A name => Task mapping of tasks we built so far
            attr_reader :tasks

            # Describes the robot. Example:
            #
            #   robot do
            #       device 'device_type'
            #       device 'device_name', :type => 'device_type'
            #   end
            #
            def robot(&block)
                if !@robot
                    new_model = Robot.new(self)
                    @robot = new_model
                end
                if block_given?
                    @robot.instance_eval(&block)
                end
                @robot
            end

            def initialize(plan, model)
                @plan      = plan
                @model     = model
                @instances = Array.new
                @tasks     = Hash.new
            end

            class InstanciatedComponent
                attr_reader :engine
                attr_reader :name
                attr_reader :model
                attr_reader :arguments
                attr_reader :using_spec
                def initialize(engine, name, model, arguments)
                    @engine    = engine
                    @name      = name
                    @model     = model
                    @arguments = arguments
                    @using_spec = Hash.new
                end
                def apply_selection(name)
                    sel = (Roby.app.orocos_tasks[name] || engine.subsystem(name))
                    if !sel && device_type = Roby.app.orocos_devices[name]
                        sel = device_type.task_model
                    end
                    sel
                end

                def using(mapping)
                    using_spec.merge!(mapping)
                    self
                end

                def instanciate(plan)
                    selection = Hash.new
                    using_spec.each do |from, to|
                        sel_from = (apply_selection(from) || from)
                        if !(sel_to = apply_selection(to))
                            raise SpecError, "#{to} is not a task model name, not a device type nor a device name"
                        end
                        selection[sel_from] = sel_to
                    end
                    model.instanciate(plan, arguments.merge(:selection => selection))
                end
            end

            # Returns the task that is currently handling the given device
            def subsystem(name)
                tasks[name]
            end

            def add(name, arguments = Hash.new)
                arguments, task_arguments = Kernel.filter_options arguments, :as => nil
                task_model = model.get(name)
                instance = InstanciatedComponent.new(self, arguments[:as], task_model, task_arguments)
                instances << instance
                instance
            end

            def instanciate
                robot.devices.each do |name, task|
                    tasks[name] = task
                end

                instances.each do |instance|
                    task = instance.instanciate(plan)
                    if name = instance.name
                        tasks[name] = task
                    end
                end
            end

            def merge
                # Get all the tasks we need to consider. That's easy,
                # they all implement the Orocos::RobyPlugin::Component model
                all_tasks = plan.find_tasks(Orocos::RobyPlugin::Component).
                    to_value_set

                remaining = all_tasks.dup
                # First pass, we look into all tasks that have no inputs in
                # +remaining+, check for duplicates and merge the duplicates

                # Second pass. The remaining tasks are cycles. For those, we
                # actually extract each of the cycles and merge all at once the
                # cycles that are identical.
            end
        end
    end
end


