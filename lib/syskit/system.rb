require 'tempfile'
module Orocos
    module RobyPlugin
        class PortDynamics
            attr_accessor :period
            attr_accessor :sample_size

            def initialize(period = nil, sample_size = nil)
                @period = period
                @sample_size = sample_size
            end
        end

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
            # The actual task
            attr_accessor :task

            # The device period in seconds
            attr_reader :period
            # How many data samples are required to represent one message from
            # this device
            attr_reader :sample_size
            # The device ID. It is dependent on the method of communication to
            # the device. For a serial line, it would be the device file
            # (/dev/ttyS0). For CAN, it would be the device ID and mask.
            attr_reader :device_id
            # Generic property map. The values are set with #set and can be
            # retrieved by calling "self.property_name". The possible values are
            # specific to the type of device
            attr_reader :properties

            def com_bus; @task_arguments[:com_bus] end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil, :device_id => nil }
            def initialize(name, device_model, options,
                           task_model, task_source_name, task_arguments)
                @name, @device_model, @task_model, @task_source_name, @task_arguments =
                    name, device_model, task_model, task_source_name, task_arguments

                @period      = options[:period]
                @sample_size = options[:sample_size]
                @device_id   = options[:device_id]
                @properties  = Hash.new
            end

            def instanciate(engine)
                task_model.instanciate(engine, task_arguments)
            end

            def set(name, *values)
                if values.size == 1
                    properties[name.to_str] = values.first
                else
                    properties[name.to_str] = values
                end
                self
            end

            dsl_attribute(:period) { |v| Float(v) }
            dsl_attribute(:sample_size) { |v| Integer(v) }
            dsl_attribute(:device_id) do |*values|
                if values.size > 1
                    values
                else
                    values.first
                end
            end
        end

        # This class represents a communication bus on the robot, i.e. a device
        # that multiplexes and demultiplexes I/O for device modules
        class CommunicationBus
            # The RobotDefinition object we are part of
            attr_reader :robot
            # The bus name
            attr_reader :name

            def initialize(robot, name, options = Hash.new)
                @robot = robot
                @name  = name
                @options = options
            end

            def through(&block)
                with_module(*RobyPlugin.constant_search_path, &block)
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

        class RobotDefinition
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

                name = options[:as].to_str.snakecase
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

                devices[name]
            end
        end

        class Engine
            extend Logger::Forward
            extend Logger::Hierarchy

            # The plan we are working on
            attr_reader :plan
            # The model we are taking our tasks from
            attr_reader :model
            # The robot on which the software is running
            attr_reader :robot
            # The instances we are supposed to build
            #
            # See #add and #remove
            attr_reader :instances
            # Prepared InstanciatedComponent instances.
            #
            # See #define
            attr_reader :defines
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
                    new_model = RobotDefinition.new(self)
                    @robot = new_model
                end
                if block_given?
                    @robot.with_module(*RobyPlugin.constant_search_path, &block)
                end
                @robot
            end

            attr_predicate :modified

            def initialize(plan, model)
                @plan      = plan
                @model     = model
                @instances = Array.new
                @tasks     = Hash.new
                @deployments = ValueSet.new
                @main_selection = Hash.new
                @defines   = Hash.new
                @modified  = false
                @merging_candidates_queries = Hash.new
                @composition_specializations = Hash.new do |h, k|
                    h[k] = Hash.new { |a, b| a[b] = Hash.new }
                end

                @dot_index = 0
            end

            class InstanciatedComponent
                attr_reader :engine
                attr_reader :name
                attr_reader :model
                attr_reader :arguments
                attr_reader :using_spec
                attr_accessor :task
                attr_predicate :mission, true
                attr_accessor :replaces

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

            def add_mission(*args)
                instance = add(*args)
                instance.mission = true
                instance
            end

            def create_instanciated_component(model, arguments = Hash.new)
                if !(model.kind_of?(Class) && model < Component)
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
                arguments, task_arguments = Kernel.filter_options arguments, :as => nil
                instance = InstanciatedComponent.new(self, arguments[:as], model, task_arguments)
            end

            def define(name, model, arguments = Hash.new)
                defines[name] = create_instanciated_component(model, arguments)
            end

            def add(model, arguments = Hash.new)
                if model.respond_to?(:to_str)
                    if !(instance = defines[model.to_str])
                        raise ArgumentError, "#{model} is not a valid instance definition added with #define"
                    end
                    instance = instance.dup
                else
                    instance = create_instanciated_component(model, arguments)
                end
                @modified = true
                instances << instance
                instance
            end

            def replace(current_task, new_task)
                if current_task.respond_to?(:task)
                    current_task = current_task.task
                end

                task = add(new_task)
                task.replaces = current_task

                if current_task
                    instances.delete_if do |instance|
                        instance.task == current_task
                    end
                end
                task
            end

            def remove(task)
                if task.kind_of?(InstanciatedComponent)
                    removed_instances, @instances = instances.partition { |t| t == task }
                elsif task.kind_of?(Roby::Task)
                    removed_instances, @instances = instances.partition { |t| t.task == task }
                    if removed_instances.empty?
                        raise ArgumentError, "#{task} has not been added through Engine#add"
                    end
                elsif task.respond_to?(:to_str)
                    removed_instances, @instances = instances.partition { |t| t.name == task.to_str }
                    if removed_instances.empty?
                        raise ArgumentError, "no task called #{task} has been instanciated through Engine#add"
                    end
                elsif task < Roby::Task || task.kind_of?(Roby::TaskModelTag)
                    removed_instances, @instances = instances.partition { |t| t.model <= task }
                    if removed_instances.empty?
                        raise ArgumentError, "no task matching #{task} have been instanciated through Engine#add"
                    end
                end

                @modified = true
                removed_instances.each do |instance|
                    if instance.task && instance.task.plan
                        plan.unmark_mission(instance.task)
                        plan.unmark_permanent(instance.task)
                    end
                end
            end

            def instanciate
                self.tasks.clear

                Orocos::RobyPlugin::Compositions.each do |composition_model|
                    composition_model.reset_autoconnection
                end

                robot.devices.each do |name, device_instance|
                    task =
                        if device_instance.task && device_instance.task.plan == plan.real_plan
                            device_instance.task
                        else
                            device_instance.instanciate(self)
                        end
                        
                    tasks[name] = plan[task]
                    device_instance.task = task
                    device_instance.task_model.
                        each_child_data_source(device_instance.task_source_name) do |child_name, _|
                            tasks["#{name}.#{child_name}"] = task
                        end
                end

                # Merge once here: the idea is that some of the drivers can
                # be shared among devices, something that is not taken into
                # account by driver instanciation
                merge_identical_tasks

                instances.each do |instance|
                    task = instance.instanciate(self)
                    if name = instance.name
                        tasks[name] = task
                    end
                    if instance.mission?
                        plan.add_mission(task)
                    else
                        plan.add_permanent(task)
                    end
                end
            end

            def to_svg(filename)
                Tempfile.open('roby_orocos_deployment') do |io|
                    io.write Roby.app.orocos_engine.to_dot
                    io.flush

                    File.open(filename, 'w') do |output_io|
                        output_io.puts(`dot -Tsvg #{io.path}`)
                    end
                end
            end

            def to_dot
                result = []
                result << "digraph {"
                result << "  rankdir=LR"
                result << "  node [shape=record,height=.1];"

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }
                all_tasks = plan.find_local_tasks(Deployment).to_value_set

                plan.find_local_tasks(Component).each do |source_task|
                    all_tasks << source_task
                    if !source_task.kind_of?(Composition)
                        source_task.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                            output_ports[source_task] << source_port
                            input_ports[sink_task]    << sink_port

                            policy_s = if policy.empty? then ""
                                       elsif policy[:type] == :data then 'data'
                                       elsif policy[:type] == :buffer then  "buffer:#{policy[:size]}"
                                       else policy.to_s
                                       end

                            result << "  #{source_task.object_id}:#{source_port} -> #{sink_task.object_id}:#{sink_port} [label=\"#{policy_s}\"];"
                        end
                    end
                    source_task.each_sink do |sink_task, connections|
                        next if !sink_task.kind_of?(Composition) && !source_task.kind_of?(Composition)
                        connections.each do |(source_port, sink_port), _|
                            output_ports[source_task] << source_port
                            input_ports[sink_task]    << sink_port

                            result << "  #{source_task.object_id}:#{source_port} -> #{sink_task.object_id}:#{sink_port} [style=dashed];"
                        end
                    end
                end

                all_tasks.each do |task|
                    task_label = task.to_s.
                        gsub(/\s+/, '').gsub('=>', ':').
                        gsub(/\[\]|\{\}/, '').gsub(/[{}]/, '\\n')
                    task_flags = []
                    task_flags << "D" if task.execution_agent
                    task_flags << "E" if task.executable?
                    task_flags << "A" if task.abstract?
                    task_flags << "C" if task.kind_of?(Composition)
                    task_label << "[#{task_flags.join(",")}]"

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

                # Check that all device instances are proper tasks (not proxies)
                robot.devices.each do |name, instance|
                    if instance.task.transaction_proxy?
                        raise InternalError, "some transaction proxies are stored in instance.task"
                    end
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

            attr_reader :composition_specializations

            # Returns if the child of +c1+ called +child_name+ has either the
            # same model than +c0+, or is a specialization of the model of +c0+
            #
            # If +c1+ has +child_name+ but c0 has not, returns true as well
            #
            # If +c0+ has +child_name+ but not +c1+, return false
            #
            # If neither have a child called +child_name+, returns true.
            def composition_child_is_specialized(child_name, c0, c1)
                result = composition_specializations[child_name][c0][c1]
                if result.nil?
                    models0 = c0.find_child(child_name)
                    models1 = c1.find_child(child_name)
                    if !models0 && !models1
                        return true
                    end
                    if !models0
                        return true
                    elsif !models1
                        return false
                    end

                    flag = Composition.is_specialized_model?(models0, models1)
                    composition_specializations[child_name][c0][c1] = flag
                    if flag
                        composition_specializations[child_name][c1][c0] = false
                    end
                    flag
                else
                    result
                end
            end

            def prepare
                model.each_composition do |composition|
                    composition.update_all_children
                end
                @merging_candidates_queries.clear
            end

            def resolve(compute_policies = true)
                prepare

                engine_plan = @plan
                plan.in_transaction do |trsc|
                    begin
                    @plan = trsc

                    instanciate

                    allocate_abstract_tasks
                    link_to_busses
                    merge_identical_tasks

                    # Now import tasks that are already in the plan and merge
                    # them. We unmark the tasks that should be replaced and run
                    # a GC pass to disconnect them to everything that is around
                    # them.
                    #
                    # NOTE: the GC pass HAS TO be done before
                    # instanciate_required_deployments, as new deployment
                    # instances would be removed by it
                    trsc.find_tasks(Component).to_a
                    instances.each do |instance|
                        if replaced_task = instance.replaces
                            replaced_task = trsc[replaced_task]
                            trsc.unmark_mission(replaced_task)
                            trsc.unmark_permanent(replaced_task)
                        end
                    end
                    trsc.static_garbage_collect do |task|
                        if !tasks.values.find { |t| t == task }
                            Engine.debug { "clearing the relations of #{task}" }
                            task.clear_relations
                        end
                    end
                    instanciate_required_deployments
                    merge_identical_tasks

                    # the tasks[] and devices mappings are updated during the
                    # merge. We replace the proxies by the corresponding tasks
                    # when applicable
                    robot.devices.each_key do |name|
                        device_task = robot.devices[name].task
                        if device_task.plan == trsc && device_task.transaction_proxy?
                            robot.devices[name].task = device_task.__getobj__
                        end
                    end
                    tasks.each_key do |name|
                        instance_task = robot.devices[name].task
                        if instance_task.plan == trsc && instance_task.transaction_proxy?
                            tasks[name].task = instance_task.__getobj__
                        end
                    end

                    # Finally, we should now only have deployed tasks. Verify it
                    # and compute the connection policies
                    validate_result(trsc)
                    if compute_policies
                        compute_connection_policies
                    end

                    trsc.static_garbage_collect do |obj|
                        trsc.remove_object(obj) if !obj.respond_to?(:__getobj__)
                    end
                    trsc.commit_transaction
                    @modified = false

                    rescue
                        Engine.fatal "Engine#resolve failed"
                        output_path = File.join(Roby.app.log_dir, "orocos-engine-plan-#{@dot_index}.dot")
                        @dot_index += 1
                        Engine.fatal "the generated plan is saved into #{output_path}"
                        File.open(output_path, 'w') do |io|
                            io.write to_dot
                        end
                        Engine.fatal "use dot -Tsvg #{output_path} > #{output_path}.svg to convert to SVG"
                        raise
                    end
                end

            ensure
                @plan = engine_plan
            end

            def allocate_abstract_tasks(validate = true)
                targets = plan.find_local_tasks(Orocos::RobyPlugin::Component).
                    abstract.
                    to_value_set

                Engine.debug "  -- Task allocation"

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
                        raise SpecError, "cannot find a concrete task for #{target} in #{target.parents.map(&:to_s).join(", ")}"
                    elsif candidates.size > 1
                        raise Ambiguous, "there are multiple candidates for #{target} (#{candidates.join(", ")}), you must select one with the 'use' statement"
                    end

                    Engine.debug { "   #{target} => #{candidates.first}" }
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
                    MERGE_SORT_TRUTH_TABLE[ [t1.fully_instanciated?, t2.fully_instanciated?] ] ||
                    MERGE_SORT_TRUTH_TABLE[ [t1.respond_to?(:__getobj__), t2.respond_to?(:__getobj__)] ]
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
                for task in task_set
                    query = @merging_candidates_queries[task.model]
                    if !query
                        required_model = task.user_required_model
                        query = @merging_candidates_queries[task.model] = plan.find_local_tasks(required_model)
                    end
                    query.reset
                    candidates = query.to_value_set & task_set
                    next if candidates.empty?

                    if task.kind_of?(Composition)
                        task_children = task.merged_relations(:each_child, true, false).to_value_set
                    end

                    for target_task in candidates
                        next if target_task == task

                        # We don't do task allocation as this level.
                        # Meaning: we merge only abstract tasks together and
                        # concrete tasks together
                        next if (target_task.abstract? ^ task.abstract?)
                        # We never replace a deployed task (i.e. target_task
                        # cannot be executable)
                        next if target_task.execution_agent
                        # Merge only if +task+ has the same child set than +target+
                        if task.kind_of?(Composition) && target_task.kind_of?(Composition)
                            target_children = target_task.merged_relations(:each_child, true, false).to_value_set
                            next if task_children != target_children
                        end
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

                        Engine.debug do
                            targets.each do |target_task|
                                Engine.debug "   #{target_task} => #{task}"
                            end
                            break
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

                Engine.debug do
                    filtered_result.map do |t, targets|
                        targets.map do |target|
                            Engine.debug "   #{target} => #{t}"
                        end
                    end
                    break
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
                        Engine.debug { "#{target_task} #{task} #{result}" }
                    end
                end
                if mapping.keys.size == target_cycle.size
                    mapping
                end
            end

            def apply_merge_mappings(mappings)
                final_merge_mappings = Hash.new
                merged_tasks = ValueSet.new
                while !mappings.empty?
                    task, targets = mappings.shift
                    targets.each do |target_task|
                        Engine.debug { "   #{target_task} => #{task}" }
                        if task.respond_to?(:merge)
                            task.merge(target_task)
                        else
                            plan.replace_task(target_task, task)
                        end

                        final_merge_mappings[target_task] = task
                        merged_tasks << task
                        plan.remove_object(target_task)
                    end

                    new_mappings = Hash.new
                    mappings.each do |task, pending_targets|
                        if !targets.include?(task)
                            pending_targets = pending_targets - targets
                            if !pending_targets.empty?
                                new_mappings[task] = pending_targets
                            end
                        end
                    end
                    mappings = new_mappings
                end

                tasks.each_key do |n|
                    if task = final_merge_mappings[tasks[n]]
                        tasks[n] = task
                        if robot.devices[n]
                            robot.devices[n].task = task
                        end
                    end
                end
                instances.each do |i|
                    if task = final_merge_mappings[i.task]
                        i.task = task
                    end
                end

                merged_tasks
            end

            def merge_tasks_next_step(task_set)
                result = ValueSet.new
                for t in task_set
                    children = t.each_sink(false).to_value_set
                    result.merge(children) if children.size > 1
                    result.merge(t.each_parent_task.to_value_set.delete_if { |parent_task| !parent_task.kind_of?(Composition) })
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
                        Engine.debug "  -- Raw merge candidates (a => b merges 'a' into 'b')"
                        merges = direct_merge_mappings(candidates)
                        Engine.debug "  -- Filtered merge candidates (a => b merges 'a' into 'b')"
                        merges = filter_direct_merge_mappings(merges)
                        Engine.debug "  -- Applying merges (a => b merges 'a' into 'b') "
                        candidates = apply_merge_mappings(merges)
                        Engine.debug
                        merged_tasks.merge(candidates)

                        candidates = merge_tasks_next_step(candidates)
                    end

                    Engine.debug "  -- Parents"
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

                    Engine.debug
                    Engine.debug " -- Cycles"
                    Engine.debug do
                        all_cycles.each_with_index do |cycle, i|
                            cycle.each do |t|
                                Engine.debug "  #{i} #{t}"
                            end
                        end
                        nil
                    end

                    all_cycles.each do |cycle_tasks|
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

                    # if there are some unconnected data sources, search for
                    # generic ports (input and/or output) on the task, and link
                    # to it.
                    if handled.values.any? { |v| v == [false, false] }
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
                    end

                    if !in_connections.empty?
                        com_bus.connect_ports(task, in_connections)
                        in_connections.each_key do |_, sink_port|
                            task.input_port_model(sink_port).needs_reliable_connection
                        end
                    end
                    if !out_connections.empty?
                        task.connect_ports(com_bus, out_connections)
                        out_connections.each_key do |_, sink_port|
                            com_bus.input_port_model(sink_port).needs_reliable_connection
                        end
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

                    # Now also import the deployment's 
                    current_contexts = task.merged_relations(:each_executed_task, true).
                        find_all { |t| !t.finished? }.
                        map(&:orocos_name).to_set

                    new_activities = (task.orogen_spec.task_activities.
                        map(&:name).to_set - current_contexts)
                    new_activities.each do |act_name|
                        plan[task.task(act_name)]
                    end
                end
            end

            # Compute the minimal update periods for each of the components that
            # are deployed
            def port_periods
                # We only act on deployed tasks, as we need to know how the
                # tasks are triggered (what activity / priority / ...)
                deployed_tasks = plan.find_local_tasks(TaskContext).
                    find_all { |t| t.execution_agent }
                
                # Get the periods from the activities themselves directly (i.e.
                # not taking into account the port-driven behaviour)
                result = Hash.new
                deployed_tasks.each do |task|
                    result[task] = task.initial_ports_dynamics
                end

                remaining = deployed_tasks.dup
                while !remaining.empty?
                    did_something = false
                    remaining.delete_if do |task|
                        old_size = result[task].size

                        finished = task.propagate_ports_dynamics(result)
                        if finished || result[task].size != old_size
                            did_something = true
                        end
                        finished
                    end
                    if !did_something
                        Engine.warn "cannot compute port periods for:"
                        remaining.each do |task|
                            port_names = task.model.each_input.map(&:name) + task.model.each_output.map(&:name)
                            port_names.delete_if { |port_name| result[task].has_key?(port_name) }

                            Engine.warn "    #{task}: #{port_names.join(", ")}"
                        end
                        break
                    end
                end

                result
            end

            def compute_connection_policies
                port_periods = self.port_periods

                all_tasks = plan.find_local_tasks(TaskContext).
                    to_value_set

                Engine.debug "computing connections"
                all_tasks.each do |source_task|
                    source_task.each_concrete_output_connection do |source_port_name, sink_port_name, sink_task, policy|
                        # Don't do anything if the policy has already been set
                        if !policy.empty?
                            Engine.debug " #{source_task}:#{source_port_name} => #{sink_task}:#{sink_port_name} already connected with #{policy}"
                            next
                        end


                        source_port = source_task.output_port_model(source_port_name)
                        sink_port   = sink_task.input_port_model(sink_port_name)
                        if !source_port
                            raise InternalError, "#{source_port_name} is not a port of #{source_task.model}"
                        elsif !sink_port
                            raise InternalError, "#{sink_port_name} is not a port of #{sink_task.model}"
                        end
                        Engine.debug { "   #{source_task}:#{source_port.name} => #{sink_task}:#{sink_port.name}" }

                        if !sink_port.needs_reliable_connection?
                            if sink_port.required_connection_type == :data
                                policy.merge! Port.validate_policy(:type => :data)
                                Engine.debug { "     result: #{policy}" }
                                next
                            elsif sink_port.required_connection_type == :buffer
                                policy.merge! Port.validate_policy(:type => :buffer, :size => 1)
                                Engine.debug { "     result: #{policy}" }
                                next
                            end
                        end

                        # Compute the buffer size
                        input_dynamics = port_periods[source_task][source_port.name]
                        if !input_dynamics || !input_dynamics.period
                            raise SpecError, "period information for port #{source_task}:#{source_port.name} cannot be computed"
                        end

                        reading_latency = if sink_task.model.triggered_by?(sink_port)
                                              sink_task.trigger_latency
                                          else
                                              [sink_task.minimal_period, sink_task.trigger_latency].max
                                          end

                        Engine.debug { "     input_period:#{input_dynamics.period} => reading_latency:#{reading_latency}" }
                        policy[:type] = :buffer

                        latency_cycles = (reading_latency / input_dynamics.period).ceil

                        size = latency_cycles * (input_dynamics.sample_size || source_port.sample_size)
                        if burst_size = source_port.burst_size
                            burst_period = source_port.burst_period
                            Engine.debug { "     burst: #{burst_size} every #{burst_period}" }
                            if burst_period == 0
                                size = [1 + burst_size, size].max
                            else
                                size += (Float(latency_cycles) / burst_period).ceil * burst_size
                            end
                        end

                        Engine.debug { "     latency:#{latency_cycles} cycles, sample_size:#{input_dynamics.sample_size}, buffer_size:#{size}" }

                        policy[:size] = size
                        policy.merge! Port.validate_policy(policy)
                        Engine.debug { "     result: #{policy}" }
                    end
                end
            end

            # Returns true if all the declared connections to the inputs of +task+ have been applied.
            # A given module won't be started until it is the case.
            #
            # If the +only_static+ flag is set to true, only ports that require
            # static connections will be considered
            def all_inputs_connected?(task, only_static)
                task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if only_static && !task.input_port_model(sink_port).static?
                        next
                    end

                    # Our source may not be initialized at all
                    if !source_task.orogen_task
                        return false
                    end

                    return false if !ActualDataFlow.linked?(source_task.orogen_task, task.orogen_task)
                    mappings = source_task.orogen_task[task.orogen_task, ActualDataFlow]
                    return false if !mappings.has_key?([source_port, sink_port])
                end
                true
            end

            # Updates an intermediate graph (RobyPlugin::RequiredDataFlow) where
            # we store the concrete connections. We don't try to be smart:
            # remove all tasks that have to be updated and add their connections
            # again
            def update_required_dataflow_graph(tasks)
                seen = ValueSet.new

                # Remove first all tasks. Otherwise, removing some tasks will
                # also remove the new edges we just added
                for t in tasks
                    RequiredDataFlow.remove(t)
                end

                # Create the new connections
                for t in tasks
                    t.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                        next if seen.include?(source_task)
                        RequiredDataFlow.add_connections(source_task, t, [source_port, sink_port] => policy)
                    end
                    t.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        next if seen.include?(sink_task)
                        RequiredDataFlow.add_connections(t, sink_task, [source_port, sink_port] => policy)
                    end
                    seen << t
                end
            end

            # Computes the connection changes that are required to make the
            # required connections (declared in the DataFlow relation) match the
            # actual ones (on the underlying modules)
            #
            # It returns nil if the change can't be computed because the Roby
            # tasks are not tied to an underlying RTT task context.
            #
            # Returns [new, removed] where
            #
            #   new = { [from_task, to_task] => { [from_port, to_port] => policy, ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Orocos::RobyPlugin::TaskContext (i.e. Roby tasks), +from_port+ and
            # +to_port+ are the port names (i.e. strings) and policy the policy
            # hash that Orocos::OutputPort#connect_to expects.
            #
            #   removed = { [from_task, to_task] => { [from_port, to_port], ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Orocos::TaskContext (i.e. the underlying RTT tasks). +from_port+ and
            # +to_port+ are the names of the ports that have to be disconnected
            # (i.e. strings)
            def compute_connection_changes(tasks)
                return if tasks.any? { |t| !t.orogen_task }

                update_required_dataflow_graph(tasks)
                new_edges, removed_edges, updated_edges =
                    RequiredDataFlow.difference(ActualDataFlow, tasks, &:orogen_task)

                new = Hash.new
                new_edges.each do |source_task, sink_task|
                    new[[source_task, sink_task]] = source_task[sink_task, RequiredDataFlow]
                end

                removed = Hash.new
                removed_edges.each do |source_task, sink_task|
                    removed[[source_task, sink_task]] = source_task[sink_task, ActualDataFlow].keys.to_set
                end

                # We have to work on +updated+. The graphs are between tasks,
                # not between ports because of how ports are handled on both the
                # orocos.rb and Roby sides. So we must convert the updated
                # mappings into add/remove pairs. Moreover, to update a
                # connection policy we need to disconnect and reconnect anyway.
                #
                # Note that it is fine from a performance point of view, as in
                # most cases one removes all connections from two components to
                # recreate other ones between other components
                updated_edges.each do |source_task, sink_task|
                    new_mapping = source_task[sink_task, RequiredDataFlow]
                    old_mapping = source_task.orogen_task[sink_task.orogen_task, ActualDataFlow]

                    new_connections     = Hash.new
                    removed_connections = Set.new
                    new_mapping.each do |ports, new_policy|
                        if old_policy = old_mapping[ports]
                            if old_policy != new_policy
                                new_connections[ports] = policy
                                removed_connections << ports
                            end
                        else
                            new_connections[ports] = policy
                        end
                    end

                    if !new_connections.empty?
                        new[[source_task, sink_task]] = new_connections
                    end
                    if !removed_connections.empty?
                        removed[[source_task, sink_task]].merge(removed_connection)
                    end
                end

                return new, removed
            end

            def update_restart_set(set, source_task, sink_task, mappings)
                if !set.include?(source_task)
                    needs_restart = mappings.any? do |source_port, sink_port|
                        source_task.output_port_model(source_port).static? && source_task.running?
                    end
                    if needs_restart
                        set << source_task
                    end
                end

                if !set.include?(sink_task)
                    needs_restart =  mappings.any? do |source_port, sink_port|
                        sink_task.input_port_model(sink_port).static? && sink_task.running?
                    end

                    if needs_restart
                        set << sink_task
                    end
                end
                set
            end

            # Apply all connection changes on the system. The principle is to
            # use a transaction-based approach: i.e. either we apply everything
            # or nothing.
            #
            # See #compute_connection_changes for the format of +new+ and
            # +removed+
            #
            # Returns a false value if it could not apply the changes and a true
            # value otherwise.
            def apply_connection_changes(new, removed)
                restart_tasks = ValueSet.new

                # Don't do anything if some of the connection changes are
                # between static ports and the relevant tasks are running
                #
                # Moreover, we check that the tasks are ready to be connected.
                # We do it only for the new set, as the removed connections are
                # obviously between tasks that can be connected ;-)
                new.each do |(source, sink), mappings|
                    if !sink.executable?(false) || !sink.is_setup? ||
                        !source.executable?(false) || !source.is_setup?
                        throw :cancelled
                    end

                    update_restart_set(restart_tasks, source, sink, mappings.keys)
                end

                restart_task_proxies = ValueSet.new
                removed.each do |(source, sink), mappings|
                    update_restart_set(restart_task_proxies, source, sink, mappings)
                end
                restart_task_proxies.each do |corba_handle|
                    klass = Roby.app.orocos_tasks[corba_handle.model.name]
                    task = plan.find_tasks(klass).running.
                        find { |t| t.orocos_name == corba_handle.name }

                    if task
                        restart_tasks << task
                    end
                end

                if !restart_tasks.empty?
                    new_tasks = Array.new
                    all_stopped = Roby::AndGenerator.new

                    restart_tasks.each do |task|
                        Engine.info { "restarting #{task}" }
                        replacement = plan.recreate(task)
                        Engine.info { "  replaced by #{replacement}" }
                        new_tasks << replacement
                        all_stopped << task.stop_event
                    end
                    new_tasks.each do |new_task|
                        all_stopped.add_causal_link new_task.start_event
                    end
                    throw :cancelled, all_stopped
                end

                # Remove connections first
                removed.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        Engine.info do
                            Engine.info "disconnecting #{source_task}:#{source_port}"
                            Engine.info "     => #{sink_task}:#{sink_port}"
                            break
                        end

                        begin
                            source_task.port(source_port).disconnect_from(sink_task.port(sink_port, false))

                        rescue CORBA::ComError => e
                            Engine.warn "CORBA error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                            Engine.warn "trying by disconnecting the output port"
                            begin
                                sink_task.port(sink_port, true).disconnect_all
                            rescue CORBA::ComError => e
                                Engine.warn "this fails again with #{e.message}. We assume that both sides are dead and that therefore the disconnection is effective"
                            end
                        end

                        ActualDataFlow.remove_connections(source_task, sink_task,
                                          [[source_port, sink_port]])
                    end
                end

                # And create the new ones
                new.each do |(from_task, to_task), mappings|
                    mappings.each do |(from_port, to_port), policy|
                        Engine.info do
                            Engine.info "connecting #{from_task}:#{from_port}"
                            Engine.info "     => #{to_task}:#{to_port}"
                            Engine.info "     with policy #{policy}"
                            break
                        end
                        from_task.orogen_task.port(from_port).connect_to(to_task.orogen_task.port(to_port), policy)
                        ActualDataFlow.add_connections(from_task.orogen_task, to_task.orogen_task,
                                                   [from_port, to_port] => policy)
                    end
                end

                true
            end
        end
    end
end


