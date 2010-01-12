module Orocos
    module RobyPlugin
        class DeviceInstance
            # The device name
            attr_reader :name
            # The device model, as a subclass of DeviceDriver
            attr_reader :device_model

            # The selected task model that allows to drive this device
            attr_reader :task_model
            # The source in +task_model+ for this device
            attr_reader :task_source_name
            # The task arguments
            attr_reader :task_arguments

            # The device period in seconds
            attr_reader :period
            # How many data samples are required to represent one message from
            # this device
            attr_reader :sample_size

            def com_bus; @task_arguments[:com_bus] end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil }
            def initialize(name, device_model, options,
                           task_model, task_source_name, task_arguments)
                @name, @device_model, @task_model, @task_source_name, @task_arguments =
                    name, device_model, task_model, task_source_name, task_arguments

                @period = options[:period]
                @sample_size = options[:sample_size]
            end

            def instanciate(engine)
                task_model.instanciate(engine, task_arguments)
            end
        end

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
                elsif device_model < DataSource && !(device_model < DeviceDriver)
                    name = device_model.name
                    if engine.model.has_device_driver?(name)
                        device_model = Orocos::RobyPlugin::DeviceDrivers.const_get(name.camelcase(true))
                    end
                end

                options, device_options = Kernel.filter_options options,
                    :as => device_model.name.gsub(/.*::/, ''),
                    :expected_model => DeviceDriver
                device_options, task_arguments = Kernel.filter_options device_options,
                    DeviceInstance::KNOWN_PARAMETERS

                name = options[:as].to_str
                if devices[name]
                    raise SpecError, "device #{name} is already defined"
                end

                if !(device_model < options[:expected_model])
                    raise SpecError, "#{device_model} is not a #{options[:expected_model].name}"
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
                    raise SpecError, "no task can handle devices of type '#{device_model}'"
                end

                task_model = tasks.first
                task_source_name = task_model.data_source_name(device_model)
                task_arguments = {"#{task_source_name}_name" => name, :com_bus => nil}.
                    merge(task_arguments)

                devices[name] = DeviceInstance.new(
                    name, device_model, device_options,
                    task_model, task_source_name, task_arguments)

                task_model
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
            # The set of deployment names we should use
            attr_reader :deployments

            # Use the deployments defined in the given project
            def use_deployments_from(project_name)
                orogen = Roby.app.load_orogen_project(project_name)
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install?
                        deployments << deployment_def.name
                    end
                end
            end

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
                @deployments = ValueSet.new
                @main_selection = Hash.new
            end

            class InstanciatedComponent
                attr_reader :engine
                attr_reader :name
                attr_reader :model
                attr_reader :arguments
                attr_reader :using_spec
                attr_reader :task

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
                    selection = engine.main_selection.merge(using_spec)
                    selection.each_key do |key|
                        value = selection[key]
                        if value.kind_of?(InstanciatedComponent)
                            selection[key] = value.task
                        end
                    end

                    @task = model.instanciate(engine, arguments.merge(:selection => selection))
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

            attr_reader :main_selection
            def use(mappings)
                mappings.each do |model, definition|
                    main_selection[model] = definition
                end
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

                robot.devices.each do |name, device_instance|
                    task = device_instance.instanciate(self)
                    tasks[name] = task
                    device_instance.task_model.
                        each_child_data_source(device_instance.task_source_name) do |child_name, _|
                            tasks["#{name}.#{child_name}"] = task
                        end
                end
                merge_identical_tasks

                instances.each do |instance|
                    task = instance.instanciate(self)
                    if name = instance.name
                        tasks[name] = task
                    end
                    plan.add_permanent(task)
                end
            end

            def to_dot
                result = []
                result << "digraph {"
                result << "  rankdir=LR"
                result << "  node [shape=record,height=.1];"

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }
                all_tasks = ValueSet.new
                plan.find_local_tasks(Component).each do |task|
                    all_tasks << task
                    task.each_sink do |target_task, connections|
                        connections.each do |(source_port, sink_port), policy|
                            output_ports[task] << source_port
                            input_ports[target_task]  << sink_port

                            result << "  #{task.object_id}:#{source_port} -> #{target_task.object_id}:#{sink_port} [label=\"#{policy}\"];"
                        end
                    end
                end

                all_tasks.each do |task|
                    task_label = task.to_s.
                        gsub(/\s+/, '').gsub('=>', ':').
                        gsub(/\[\]|\{\}/, '').gsub(/[{}]/, '\\n')
                    if task.execution_agent
                        task_label << "[E]"
                    elsif task.abstract?
                        task_label << "[A]"
                    end

                    inputs  = input_ports[task].to_a.sort
                    outputs = output_ports[task].to_a.sort

                    label = ""
                    if !inputs.empty?
                        label << inputs.map do |name|
                            "<#{name}> #{name}"
                        end.join("|")
                        label << "|"
                    end
                    label << "<main> #{task_label}"
                    if !outputs.empty?
                        label << "|"
                        label << outputs.map do |name|
                            "<#{name}> #{name}"
                        end.join("|")
                    end

                    result << "  #{task.object_id} [label=\"#{label}\"];"
                end

                result << "};"
                result.join("\n")
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
                # Check for the presence of abstract tasks
                still_abstract = plan.find_local_tasks(Component).
                    abstract.to_a.
                    delete_if do |p|
                        p.parent_objects(Roby::TaskStructure::Dependency).to_a.empty?
                    end

                if !still_abstract.empty?
                    raise Ambiguous, "there are ambiguities left in the plan: #{still_abstract}"
                end

                # Check for the presence of non-deployed tasks
                not_deployed = plan.find_local_tasks(TaskContext).
                    find_all { |t| !t.execution_agent }.
                    delete_if do |p|
                        p.parent_objects(Roby::TaskStructure::Dependency).to_a.empty?
                    end
                if !not_deployed.empty?
                    raise Ambiguous, "there are tasks for which it exists no deployed equivalent: #{not_deployed.map(&:to_s)}"
                end
            end

            def resolve
                engine_plan = @plan
                plan.in_transaction do |trsc|
                    @plan = trsc
                    instanciate
                    allocate_abstract_tasks

                    merge_identical_tasks
                    allocate_abstract_tasks

                    STDERR.puts "======== Now merging deployed tasks =========="
                    instanciate_required_deployments
                    merge_identical_tasks

                    validate_result(trsc)
                    link_to_busses

                    trsc.commit_transaction
                end

            ensure
                @plan = engine_plan
            end

            def allocate_abstract_tasks(validate = true)
                targets = plan.find_local_tasks(Orocos::RobyPlugin::Component).
                    abstract.
                    to_value_set

                STDERR.puts "  -- Task allocation"

                targets.each do |target|
                    candidates = plan.find_local_tasks(target.fullfilled_model.first).
                        not_abstract.
                        find_all { |candidate| candidate.can_merge?(target) }

                    candidates.delete_if do |candidate_task|
                        candidates.any? do |t|
                            if t != candidate_task
                                comparison = merge_sort_order(t, candidate_task)
                                comparison && comparison < 0
                            end
                        end
                    end

                    if candidates.empty?
                        raise SpecError, "cannot find a concrete task for #{target}"
                    elsif candidates.size > 1
                        raise Ambiguous, "there are multiple candidates for #{target} (#{candidates.join(", ")}), you must select one with the 'use' statement"
                    end

                    STDERR.puts "   #{target} => #{candidates.first}"
                    candidates.first.merge(target)
                    plan.remove_object(target)
                end
            end

            MERGE_SORT_TRUTH_TABLE = { [true, true] => nil, [true, false] => -1, [false, true] => 1, [false, false] => nil }
            # Will return -1 if +t1+ is a better merge candidate than +t2+, 1 on
            # the contrary and nil if they are not comparable.
            def merge_sort_order(t1, t2)
                return if !(t1.model <=> t2.model)

                MERGE_SORT_TRUTH_TABLE[ [t1.execution_agent, t2.execution_agent] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [!t1.abstract?, !t2.abstract?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [t1.fully_instanciated?, t2.fully_instanciated?] ]
            end

            def find_merge_roots(task_set)
                task_set.map do |t|
                    inputs = t.parent_objects(Flows::DataFlow).to_value_set
                    if !inputs.intersects?(task_set)
                        children = t.children.to_value_set
                        if !children.intersects?(task_set)
                            [t, inputs, children]
                        end
                    end
                end.compact
            end

            def direct_merge_mappings(task_set)
                merge_graph = BGL::Graph.new
                task_set.each do |task|
                    task_children = task.each_child(false).to_value_set

                    task_set.each do |target_task|
                        next if target_task == task
                        # We don't do task allocation as this level.
                        # Meaning: we merge only abstract tasks together and
                        # concrete tasks together
                        next if (target_task.abstract? ^ task.abstract?)
                        # We never replace an executable task (i.e. target_task
                        # cannot be executable)
                        next if target_task.execution_agent
                        # Merge only if +task+ has the same child set than +target+
                        target_children = target_task.each_child(false).to_value_set
                        next if !task_children.include_all?(target_children)
                        # Finally, call #can_merge?
                        next if !task.can_merge?(target_task)

                        merge_graph.link(task, target_task, nil)
                    end
                end

                result = merge_graph.components.map do |cluster|
                    cluster.map do |task|
                        targets = task.
                            enum_child_objects(merge_graph).
                            to_a
                        targets.each do |target_task|
                            STDERR.puts "   #{target_task} => #{task}"
                        end
                        [task, targets] if !targets.empty?
                    end.compact
                end
                merge_graph.clear
                result
            end

            def filter_direct_merge_mappings(result)
                # Now, remove the merge specifications that are
                # redundant/useless.
                filtered_result = Array.new
                for mapping in result
                    mapping.sort! do | (t1, target1), (t2, target2) |
                        merge_sort_order(t1, t2) || (target1.size <=> target2.size)
                    end

                    while !mapping.empty?
                        t1, target1 = mapping.shift
                        filtered_result.push [t1, target1]
                        mapping = mapping.map do |t2, target2|
                            target2.delete(t1)
                            if merge_sort_order(t1, t2) == 0
                                if target1.include?(t2)
                                    target2 = target2 - target1
                                    [t2, target2] if !target2.empty?
                                else
                                    common = (target1 & target2)
                                    if !common.empty?
                                        raise Ambiguous, "both #{t1} and #{t2} can be selected for #{common.map(&:name).join(", ")}"
                                    end
                                end
                            else
                                target2 = target2 - target1
                                [t2, target2] if !target2.empty?
                            end
                        end.compact
                    end
                end
                filtered_result.each do |t, targets|
                    targets.each do |target|
                        STDERR.puts "   #{target} => #{t}"
                    end
                end
                filtered_result
            end

            # Find a mapping that allows to merge +cycle+ into +target_cycle+.
            # Returns nil if there is none.
            def cycle_merge_mapping(target_cycle, cycle)
                return if target_cycle.size != cycle.size

                mapping = Hash.new
                target_cycle.each do |target_task, target_inputs, target_children|
                    cycle.each do |task, inputs, children|
                        result = if can_merge?(target_task, target_inputs, target_children, 
                                            task, inputs, children)

                            return if mapping.has_key?(target_task)
                            mapping[target_task] = task
                        end
                        STDERR.puts "#{target_task} #{task} #{result}"
                    end
                end
                if mapping.keys.size == target_cycle.size
                    mapping
                end
            end

            def apply_merge_mappings(mappings)
                merged_tasks = ValueSet.new
                while !mappings.empty?
                    task, targets = mappings.shift
                    targets.each do |target_task|
                        STDERR.puts "   #{target_task} => #{task}"
                        if task.respond_to?(:merge)
                            task.merge(target_task)
                        else
                            plan.replace_task(target_task, task)
                        end
                        tasks.each_key do |n|
                            if tasks[n] == target_task
                                tasks[n] = task
                            end
                        end

                        merged_tasks << task
                        plan.remove_object(target_task)
                    end
                    mappings.delete_if do |task, pending_targets|
                        if targets.include?(task)
                            true
                        else
                            pending_targets.delete_if { |t| targets.include?(t) }
                            false
                        end
                    end
                end
                merged_tasks
            end

            def merge_tasks_next_step(task_set)
                result = ValueSet.new
                for t in task_set
                    children = t.each_sink(false).to_value_set
                    result.merge(children) if children.size > 1
                end
                result
            end

            def merge_identical_tasks
                # Get all the tasks we need to consider. That's easy,
                # they all implement the Orocos::RobyPlugin::Component model
                all_tasks = plan.find_local_tasks(Orocos::RobyPlugin::Component).
                    to_value_set

                # The first pass of the algorithm looks that the tasks that have
                # the same inputs, checks if they can be merged and do so if
                # they can.
                #
                # The algorithm is seeded by the tasks that already have the
                # same inputs and the ones that have no inputs. It then
                # propagates to the children of the merged tasks and so on.
                candidates = all_tasks.dup

                merged_tasks = ValueSet.new
                while !candidates.empty?
                    merged_tasks.clear

                    while !candidates.empty?
                        STDERR.puts "  -- Raw merge candidates"
                        merges = direct_merge_mappings(candidates)
                        STDERR.puts "  -- Filtered merge candidates"
                        merges = filter_direct_merge_mappings(merges)
                        STDERR.puts "  -- Applying merges"
                        candidates = apply_merge_mappings(merges)
                        STDERR.puts
                        merged_tasks.merge(candidates)

                        candidates = merge_tasks_next_step(candidates)
                    end

                    STDERR.puts "  -- Parents"
                    for t in merged_tasks
                        parents = t.each_parent_task.to_value_set
                        candidates.merge(parents) if parents.size > 1
                    end
                end
            end

            # This is attic code, for when we will be able to handle cycles.
            def merge_cycles # :nodoc:
                # Second pass. The remaining tasks are or depend on cycles. For
                # those, we actually extract each of the cycles and merge all at
                # once the cycles that are identical.
                while !remaining.empty?
                    # Extract the leaves in the dependency graph
                    roots = remaining.map do |t|
                        inputs   = t.parent_objects(Flows::DataFlow).to_value_set
                        children = t.children.to_value_set
                        if !children.intersects?(remaining)
                            [t, inputs, children]
                        end
                    end.compact
                    root_set  = roots.map { |t, _| t }.to_value_set
                    remaining -= root_set

                    # Now extract the cycles at that level
                    all_cycles = Array.new
                    Flows::DataFlow.generated_subgraphs(root_set, true).
                        each do |cycle_set|
                            cycle_set &= root_set
                            cycle, roots = roots.partition do |task, _|
                                cycle_set.include?(task)
                            end
                            all_cycles << cycle
                        end

                    STDERR.puts
                    STDERR.puts " -- Cycles"
                    all_cycles.each_with_index do |cycle, i|
                        cycle.each do |t|
                            STDERR.puts "  #{i} #{t}"
                        end
                    end

                    all_cycles.each do |cycle_tasks|
                        STDERR.puts direct_merge_mappings(cycle_tasks).to_s
                        # Consider that stuff that is *not* in cycle_tasks is
                        # common to sub-cycles
                        raise NotImplementedError
                    end

                    # Now find matching cycles
                    while !all_cycles.empty?
                        cycle = all_cycles.pop

                        all_cycles.delete_if do |other_cycle|
                            mapping = cycle_merge_mapping(other_cycle, cycle)
                            next if !mapping

                            mapping.each do |from, to|
                                from.merge(to)
                            end
                            true
                        end
                    end
                end
            end

            def link_to_busses
                candidates = plan.find_local_tasks(Orocos::RobyPlugin::DeviceDriver).
                    find_all { |t| t.com_bus }.
                    to_value_set

                candidates.each do |task|
                    if !(com_bus = tasks[task.com_bus])
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
                    task.model.each_root_data_source do |source_name, source_model|
                        next if !(source_model < DeviceDriver)
                        device_spec = robot.devices[task.arguments["#{source_name}_name"]]
                        next if !device_spec || !device_spec.com_bus

                        in_ports  = in_candidates.find_all  { |p| p.name =~ /#{source_name}/i }
                        out_ports = out_candidates.find_all { |p| p.name =~ /#{source_name}/i }
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
            def instanciate_required_deployments
                deployments.each do |deployment_name|
                    model = Roby.app.orocos_deployments[deployment_name]
                    task  = plan.find_tasks(model).to_a.first
                    task ||= model.new
                    task.robot = robot
                    plan.add(task)
                    contexts = task.instanciate_all_tasks
                end
            end
        end
    end
end


