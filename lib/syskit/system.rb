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

            # Returns the task that is currently handling the given device
            def device(name)
                robot.devices[name]
            end

            def initialize(plan, model)
                @plan      = plan
                @model     = model
                @instances = Array.new
            end

            class InstanciatedComponent
                attr_reader :engine
                attr_reader :model
                attr_reader :arguments
                attr_reader :selection
                def initialize(engine, model, arguments)
                    @engine    = engine
                    @model     = model
                    @arguments = arguments
                    @selection = Hash.new
                end
                def apply_selection(name)
                    sel = Roby.app.orocos_tasks[name] || engine.device(name)
                    if !sel && device_type = Roby.app.orocos_devices[name]
                        sel = device_type.task_model
                    end
                    if !sel
                        raise SpecError, "I know nothing about '#{name}'"
                    end
                    sel
                end

                def using(mapping)
                    mapping.each do |from, to|
                        sel_from = apply_selection(from)
                        sel_to = apply_selection(to)
                        selection[sel_from] = sel_to
                    end
                end
                def instanciate(plan)
                    model.instanciate(plan, arguments.merge(:selection => selection))
                end
            end

            def add(name, arguments = Hash.new)
                task_model = model.get(name)
                instance = InstanciatedComponent.new(self, task_model, arguments)
                instances << instance
                instance
            end

            def instanciate
                instances.each do |instance|
                    instance.instanciate(plan)
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


