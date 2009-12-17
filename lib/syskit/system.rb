module Orocos
    module RobyPlugin
        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class CommunicationBus
            # The Robot object we are part of
            attr_reader :robot
            # The bus name
            attr_reader :name

            def initialize(robot, name, options = Hash.new)
                @robot = robot
                @name  = name
                @options = options
            end

            def through(&block)
                instance_eval(&block)
            end

            # Used by the #through call to override com_bus specification.
            def device(type_name, options = Hash.new)
                # Check that we do have the configuration data for that device,
                # and declare it as being passing through us.
                if options[:com_bus] || options['com_bus']
                    raise SpecError, "cannot use the 'com_bus' option in a through block"
                end
                options[:com_bus] = self.name
                robot.device(type_name, options)
            end
        end

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

            def com_bus(type_name, options = Hash.new)
                bus_options, _ = Kernel.filter_options options, :as => type_name
                name = bus_options[:as].to_str
                com_busses[name] = CommunicationBus.new(self, name, options)

                device(type_name, options)
            end

            def through(com_bus, &block)
                bus = com_busses[com_bus]
                if !bus
                    raise SpecError, "communication bus #{com_bus} does not exist"
                end
                bus.through(&block)
                bus
            end

            def device(device_model, options = Hash.new)
                if device_model.respond_to?(:to_str)
                    device_model = Orocos::RobyPlugin::DeviceDrivers.const_get(device_model.to_str.camelcase(true))
                end

                options, device_options = Kernel.filter_options options,
                    :as => device_model.name.gsub(/.*::/, ''),
                    :expected_model => DeviceDriver

                name = options[:as].to_str
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                if !(device_model < options[:expected_model])
                    raise SpecError, "device #{device_type} is not a #{options[:expected_model]}"
                end

                # Since we want to drive a particular device, we actually need a
                # concrete task model. So, search for one.
                #
                # Get all task models that implement this device
                tasks = Roby.app.orocos_tasks.
                    find_all { |_, t| t.fullfills?(device_model) }.
                    map { |_, t| t }

                # Now, get the most abstract ones
                tasks.delete_if do |model|
                    tasks.any? { |t| model < t }
                end

                if tasks.size > 1
                    raise Ambiguous, "#{tasks.map(&:name).join(", ")} can all handle '#{name}', please select one explicitely with the 'using' statement"
                elsif tasks.empty?
                    raise SpecError, "no task can handle devices of type '#{device_type}'"
                end

                task_model = tasks.first
                data_source_name = task_model.data_source_name(device_model)
                device_arguments = {"#{data_source_name}_name" => name, :com_bus => nil}
                task = task_model.instanciate(engine, device_arguments.merge(device_options))
                devices[name] = task

                task_model.each_child_data_source(data_source_name) do |child_name, _|
                    devices["#{name}.#{child_name}"] = task
                end

                task
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

                def use(mapping)
                    using_spec.merge!(mapping)
                    self
                end

                def instanciate(engine)
                    model.instanciate(engine, arguments.merge(:selection => using_spec))
                end
            end

            # Returns the task that is currently handling the given device
            def subsystem(name)
                tasks[name]
            end

            def apply_selection(seed)
                if seed.kind_of?(Class) && seed < Component
                    return seed
                end

                name = seed.to_str
                sel = (Roby.app.orocos_tasks[name] || subsystem(name))

                if !sel && model.has_interface?(name)
                    sel = Interfaces.const_get(name.camelcase(true)).task_model
                end
                if !sel && model.has_device_driver?(name)
                    sel = DeviceDrivers.const_get(name.camelcase(true)).task_model
                end
                sel
            end

            def add(model, arguments = Hash.new)
                if !(model.kind_of?(Class) && model < Component)
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
                arguments, task_arguments = Kernel.filter_options arguments, :as => nil
                instance = InstanciatedComponent.new(self, arguments[:as], model, task_arguments)
                instances << instance
                instance
            end

            def instanciate
                self.tasks.clear

                Orocos::RobyPlugin::Compositions.each do |composition_model|
                    if composition_model.respond_to?(:compute_autoconnection)
                        composition_model.compute_autoconnection
                    end
                end

                robot.devices.each do |name, task|
                    proxy = plan[task]
                    tasks[name] = proxy
                    plan.add_permanent(proxy)
                end

                instances.each do |instance|
                    task = instance.instanciate(self)
                    if name = instance.name
                        tasks[name] = task
                    end
                    plan.add_permanent(task)
                end
            end

            def pretty_print(pp)
                pp.text "-- Tasks"
                pp.nest(2) do
                    pp.breakable
                    plan.each_task do |task|
                        pp.text "#{task}"
                        pp.nest(4) do
                            pp.breakable
                            pp.seplist(task.children.to_a) do |t|
                                pp.text "#{t}"
                            end
                        end
                        pp.breakable
                    end
                end

                pp.breakable
                pp.text "-- Connections"
                pp.nest(4) do
                    pp.breakable
                    Flows::DataFlow.each_edge do |from, to, info|
                        pp.text "#{from}"
                        pp.breakable
                        pp.text "  => #{to} (#{info})"
                        pp.breakable
                    end
                end
            end

            def validate_result(plan)
                still_abstract = plan.find_tasks(Component).
                    abstract.to_a

                still_abstract.delete_if do |p|
                    p.parent_objects(Roby::TaskStructure::Dependency).to_a.empty?
                end

                if !still_abstract.empty?
                    raise Ambiguous, "there are ambiguities left in the plan: #{still_abstract}"
                end
            end

            def resolve
                engine_plan = @plan
                plan.in_transaction do |trsc|
                    @plan = trsc
                    instanciate
                    allocate_abstract_tasks
                    merge_identical_tasks

                    validate_result(trsc)
                    link_to_busses

                    trsc.commit_transaction
                end

                puts "========== Instanciation Results ==============="
                pp self
                puts "================================================"
                puts

            ensure
                @plan = engine_plan
            end

            def allocate_abstract_tasks
                all_tasks = plan.find_tasks(Orocos::RobyPlugin::Component).
                    to_value_set
                targets = all_tasks.find_all { |t| t.abstract? }

                STDERR.puts "  -- Task allocation"

                targets.each do |t|
                    candidates = plan.find_tasks(t.fullfilled_model.first).
                        not_abstract.
                        find_all { |candidate| candidate.can_merge?(t) }

                    if candidates.empty?
                        raise SpecError, "cannot find a concrete task for #{t}"
                    elsif candidates.size > 1
                        raise Ambiguous, "there are multiple candidates for #{t} (#{candidates.join(", ")}), you must select one with the 'use' statement"
                    end

                    STDERR.puts "   #{candidates.first} => #{t}"
                    candidates.first.merge(t)
                end
            end

            def merge_identical_tasks
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
                    STDERR.puts "  -- Tasks"
                    STDERR.puts "   " + roots.map { |t, _| t.to_s }.join("\n   ")

                    # Create mergeability associations. +merge+ maps a task to
                    # all the tasks it can replace
                    merges = Hash.new { |h, k| h[k] = ValueSet.new }
                    STDERR.puts "  -- Merge candidates"
                    roots.each do |task, task_inputs, task_children|
                        next if task.abstract?
                        roots.each do |target_task, target_inputs, target_children|
                            next if target_task == task
                            next if !task_children.include_all?(target_children)
                            next if (task_inputs & target_inputs).size != task_inputs.size
                            if task.can_merge?(target_task)
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
                            if task.respond_to?(:merge)
                                task.merge(target_task)
                            else
                                plan.replace_task(target_task, task)
                            end
                        end
                        merges.delete_if do |task, pending_targets|
                            if targets.include?(task)
                                true
                            else
                                pending_targets.delete_if { |t| targets.include?(t) }
                                false
                            end
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

            def link_to_busses
                candidates = plan.find_tasks(Orocos::RobyPlugin::DeviceDriver).
                    find_all { |t| t.com_bus }.
                    to_value_set

                candidates.each do |task|
                    if !(com_bus = plan[robot.devices[task.com_bus]])
                        raise SpecError, "there is no communication bus named #{task.com_bus}"
                    end

                    # Assume that if the com bus is one of our dependencies,
                    # then it means we are already linked to it
                    next if task.depends_on?(com_bus)

                    # Enumerate in/out ports on task of the bus datatype
                    message_type = Orocos.registry.get(com_bus.model.message_type).name
                    out_candidates = task.model.each_output.find_all do |p|
                        p.type.name == message_type
                    end
                    in_candidates = task.model.each_input.find_all do |p|
                        p.type.name == message_type
                    end
                    if out_candidates.empty? && in_candidates.empty?
                        raise SpecError, "#{task} is supposed to be connected to #{com_bus}, but #{task.model.name} has no ports of type #{message_type} that would allow to connect to it"
                    end

		    task.depends_on com_bus

                    in_connections  = Hash.new
                    out_connections = Hash.new
                    handled    = Hash.new
                    used_ports = Set.new
                    task.model.each_root_data_source do |source_name, _|
                        in_ports  = in_candidates.find_all  { |p| p.name =~ /#{source_name}/ }
                        out_ports = out_candidates.find_all { |p| p.name =~ /#{source_name}/ }
                        if in_ports.size > 1
                            raise Ambiguous, "there are multiple options to connect #{com_bus.name} to #{source_name} in #{task}: #{in_ports.map(&:name)}"
                        elsif out_ports.size > 1
                            raise Ambiguous, "there are multiple options to connect #{source_name} in #{task} to #{com_bus.name}: #{out_ports.map(&:name)}"
                        end

                        handled[source_name] = [!out_ports.empty?, !in_ports.empty?]
                        if !in_ports.empty?
                            port = in_ports.first
                            used_ports << port.name
                            in_connections[ [com_bus.output_name_for(source_name), port.name] ] = Hash.new
                        end
                        if !out_ports.empty?
                            port = out_ports.first
                            used_ports << port.name
                            out_connections[ [port.name, com_bus.input_name_for(source_name)] ] = Hash.new
                        end
                    end

                    # Remove handled ports from in_candidates and
                    # out_candidates, and check if there is a generic
                    # input/output port in the component
                    in_candidates.delete_if  { |p| used_ports.include?(p.name) }
                    out_candidates.delete_if { |p| used_ports.include?(p.name) }

                    if in_candidates.size > 1
                        raise Ambiguous, "ports #{in_candidates.map(&:name).join(", ")} are not used while connecting #{task} to #{com_bus}"
                    elsif in_candidates.size == 1
                        # One generic input port
                        if !task.bus_name
                            raise SpecError, "#{task} has one generic input port '#{in_candidates.first.name}' but no bus name"
                        end
                        in_connections[ [com_bus.output_name_for(task.bus_name), in_candidates.first.name] ] = Hash.new

                    end

                    if out_candidates.size > 1
                        raise Ambiguous, "ports #{out_candidates.map(&:name).join(", ")} are not used while connecting #{task} to #{com_bus}"
                    elsif out_candidates.size == 1
                        # One generic output port
                        if !task.bus_name
                            raise SpecError, "#{task} has one generic output port '#{out_candidates.first.name} but no bus name"
                        end
                        out_connections[ [out_candidates.first.name, com_bus.input_name_for(task.bus_name)] ] = Hash.new
                    end

                    if !in_connections.empty?
                        com_bus.connect_ports(task, in_connections)
                    end
                    if !out_connections.empty?
                        task.connect_ports(com_bus, out_connections)
                    end
                end
                nil
            end
        end
    end
end


