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

                devices[name] = device_model.task_model.instanciate(engine, {:device_name => name}.merge(device_options))
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
                    engine.apply_selection(name)
                end

                def using(mapping)
                    using_spec.merge!(mapping)
                    self
                end

                def instanciate(engine)
                    selection = Hash.new
                    using_spec.each do |from, to|
                        sel_from = (apply_selection(from) || from)
                        if !(sel_to = apply_selection(to))
                            raise SpecError, "#{to} is not a task model name, not a device type nor a device name"
                        end
                        selection[sel_from] = sel_to
                    end
                    model.instanciate(engine, arguments.merge(:selection => selection))
                end
            end

            # Returns the task that is currently handling the given device
            def subsystem(name)
                tasks[name]
            end

            def apply_selection(name)
                sel = (Roby.app.orocos_tasks[name] || subsystem(name))
                if !sel && device_type = Roby.app.orocos_devices[name]
                    sel = device_type.task_model
                end
                sel
            end

            def add(name, arguments = Hash.new)
                arguments, task_arguments = Kernel.filter_options arguments, :as => nil
                task_model = model.get(name)
                instance = InstanciatedComponent.new(self, arguments[:as], task_model, task_arguments)
                instances << instance
                instance
            end

            def instanciate
                model.subsystems.each_value do |composition_model|
                    if composition_model.respond_to?(:compute_autoconnection)
                        composition_model.compute_autoconnection
                    end
                end

                robot.devices.each do |name, task|
                    tasks[name] = task
                end

                instances.each do |instance|
                    task = instance.instanciate(self)
                    if name = instance.name
                        tasks[name] = task
                    end
                    plan.add_permanent(task)
                end
            end

            def resolve
                instanciate
                merge
            end

            def merge
                # Get all the tasks we need to consider. That's easy,
                # they all implement the Orocos::RobyPlugin::Component model
                all_tasks = plan.find_tasks(Orocos::RobyPlugin::Component).
                    to_value_set

                # First pass, we look into all tasks that have no inputs in
                # +remaining+, check for duplicates and merge the duplicates
                remaining = all_tasks.dup
                

                rank = 1
                old_size = nil
                while remaining.size != 0 && (old_size != remaining.size)
                    old_size = remaining.size
                    rank += 1
                    roots = remaining.map do |t|
                        inputs  = t.parent_objects(Flows::DataFlow).to_value_set
                        if !inputs.intersects?(remaining)
                            children = t.children.to_value_set
                            if !children.intersects?(remaining)
                                [t, inputs, children]
                            end
                        end
                    end.compact
                    remaining -= roots.map { |t, _| t }.to_value_set
                    puts "  -- Tasks"
                    puts "   " + roots.map { |t, _| t.to_s }.join("\n   ")

                    # Create mergeability associations. +merge+ maps a task to
                    # all the tasks it can replace
                    merges = Hash.new { |h, k| h[k] = ValueSet.new }
                    STDERR.puts "  -- Merge candidates"
                    roots.each do |task, task_inputs, task_children|
                        roots.each do |target_task, target_inputs, target_children|
                            next if target_task == task
                            next if !task_children.include_all?(target_children)
                            next if (task_inputs & target_inputs).size != task_inputs.size
                            if task.can_replace?(target_task)
                                merges[task] << target_task
                                STDERR.puts "   #{task} => #{target_task}"
                            end
                        end
                    end

                    # Now, just do the replacement in a greedy manner, i.e. take
                    # the task that can replace the most other tasks and so on
                    # ...
                    merges = merges.to_a.sort_by { |task, targets| targets.size }
                    while !merges.empty?
                        task, targets = merges.shift
                        targets.each do |target_task|
                            plan.replace_task(target_task, task)
                        end
                        merges.delete_if do |task, _|
                            targets.include?(task)
                        end
                    end

                    STDERR.puts
                end

                # Second pass. The remaining tasks are cycles. For those, we
                # actually extract each of the cycles and merge all at once the
                # cycles that are identical.
                if !remaining.empty?
                    raise NotImplementedError
                end
            end

            def create_communication_busses
            end
        end
    end
end


