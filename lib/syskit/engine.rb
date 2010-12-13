require 'tempfile'
class Object
    def dot_id
        id = object_id
        if id < 0
            0xFFFFFFFFFFFFFFFF + id
        else
            id
        end
    end
end

module Orocos
    module RobyPlugin
        # Used by the to_dot* methods for color allocation
        attr_reader :current_color
        # A set of colors to be used in graphiz graphs
        COLOR_PALETTE = %w{#FF9955 #FF0000 #bb9c21 #37c637 #62816e #2A7FFF #AA00D4 #D40055 #0000FF}
        # Returns a color from COLOR_PALETTE, rotating each time the method is
        # called. It is used by the to_dot* methods.
        def self.allocate_color
            @current_color = (@current_color + 1) % COLOR_PALETTE.size
            COLOR_PALETTE[@current_color]
        end
        @current_color = 0

        # Class that is used to represent a binding of a service model with an
        # actual task instance during the instanciation process
        class InstanciatedDataService
            # The ProvidedDataService instance that represents the data service
            attr_reader :provided_service_model
            # The task instance we are bound to
            attr_reader :task
            def initialize(task, provided_service_model)
                @task, @provided_service_model = task, provided_service_model
            end

            def fullfills?(*args)
                provided_service_model.model.fullfills?(*args)
            end
        end

        # Representation of a task requirement. Used internally by Engine
        class InstanciatedComponent
            # The Engine instance
            attr_reader :engine
            # The name provided to Engine#add
            attr_accessor :name
            # The component model narrowed down from +base_model+ using
            # +using_spec+
            attr_reader :model
            # The component model specified by #add
            attr_reader :base_model
            # The arguments that should be passed to the task's #instanciate
            # method (and, in fine, to the component model)
            attr_reader :arguments
            # The actual selection given to Engine#add
            attr_reader :using_spec
            # The actual task. It is set after #resolve has been called
            attr_accessor :task
            ##
            # :method: mission?
            #
            # True if the component should be marked as a mission in the
            # plan manager. It is set to true by Engine#add_mission
            attr_predicate :mission, true
            # The task this new task replaces. It is set by Engine#replace
            attr_accessor :replaces

            def initialize(engine, name, model, arguments)
                @engine    = engine
                @name      = name
                @model     = @base_model = model
                @arguments = arguments
                @using_spec = Hash.new
            end

            ##
            # :call-seq:
            #   use 'child_name' => 'component_model_or_device'
            #   use 'child_name' => ComponentModel
            #   use ChildModel => 'component_model_or_device'
            #   use ChildModel => ComponentModel
            #   use Model1, Model2, Model3
            #
            # Provides explicit selections for the children of compositions
            #
            # In the first two forms, provides an explicit selection for a
            # given child. The selection can be given either by name (name
            # of the model and/or of the selected device), or by directly
            # giving the model object.
            #
            # In the second two forms, provides an explicit selection for
            # any children that provide the given model. For instance,
            #
            #   use IMU => XsensImu::Task
            #
            # will select XsensImu::Task for any child that provides IMU
            #
            # Finally, the third form allows to specify preferences without
            # being specific about where to put them. If ambiguities are
            # found, and if only one of the possibility is listed there,
            # then that possibility will be selected. It has a lower
            # priority than the explicit selection.
            #
            # See also Composition#instanciate
            def use(*mapping)
                result = Hash.new
                mapping.delete_if do |element|
                    if element.kind_of?(Hash)
                        result.merge!(element)
                    else
                        result[nil] ||= Array.new
                        result[nil] << element
                    end
                end
                using_spec.merge!(result)

                narrow_model
                self
            end

            # Computes the value of +model+ based on the current selection
            # (in using_spec) and the base model specified in #add or
            # #define
            def narrow_model
                Engine.debug do
                    Engine.debug "narrowing model for #{name}"
                    Engine.debug "  from #{base_model.short_name}"
                    break
                end
                selection = Hash.new
                using_spec.each_key do |key|
                    if result = resolve_explicit_selection(using_spec[key])
                        selection[key] = result
                    end
                end
                candidates = base_model.narrow(selection)
                @model =
                    if candidates.size == 1
                        candidates.find { true }
                    else
                        base_model
                    end

                Engine.debug do
                    Engine.debug "  found #{@model.short_name}"
                    break
                end
            end

            # Resolves a selection given through the #use method
            #
            # It can take, as input, one of:
            # 
            # * an array, in which case it is called recursively on each of
            #   the array's elements.
            # * an InstanciatedComponent (returned by Engine#add)
            # * a name
            #
            # In the latter case, the name refers either to a device name,
            # or to the name given through the ':as' argument to Engine#add.
            # A particular service can also be selected by adding
            # ".service_name" to the component name.
            #
            # The returned value is either an array of resolved selections,
            # a Component instance or an InstanciatedDataService instance.
            def resolve_explicit_selection(value)
                if value.kind_of?(MasterDeviceInstance) || value.kind_of?(SlaveDeviceInstance)
                    value = value.name
                end

                if value.kind_of?(InstanciatedComponent)
                    value.task
                elsif value.respond_to?(:to_str)
                    value = value.to_str
                    if !(selected_object = engine.tasks[value])
                        if selected_object = engine.robot.devices[value]
                            # Do a weak selection and return the device's
                            # task model
                            return selected_object.task_model
                        else
                            raise SpecError, "#{value} does not refer to a known task or device"
                        end
                    end

                    # Check if a service has explicitely been selected, and
                    # if it is the case, return it instead of the complete
                    # task
                    service_names = value.split '.'
                    service_names.shift # remove the task name
                    if !selected_object.kind_of?(Component) || service_names.empty? 
                        selected_object
                    else
                        candidate_service = selected_object.model.find_data_service(service_names.join("."))

                        if !candidate_service && service_names.size == 1
                            # Might still be a slave of a main service
                            services = selected_object.model.each_data_service.
                                find_all { |srv| !srv.master? && srv.master.main? && srv.name == service_names.first }

                            if services.empty?
                                raise SpecError, "#{value} is not a known device, or an instanciated composition"
                            elsif services.size > 1
                                raise SpecError, "#{value} can refer to multiple objects"
                            end
                            candidate_service = services.first
                        end

                        InstanciatedDataService.new(selected_object, candidate_service)
                    end
                elsif value.respond_to?(:to_ary)
                    value.map(&method(:resolve_explicit_selection))
                else
                    value
                end
            end

            def verify_result_in_transaction(key, result)
                if result.respond_to?(:to_ary)
                    result.each { |obj| verify_result_in_transaction(key, obj) }
                    return
                end

                task = result
                if result.respond_to?(:task)
                    task = result.task
                end
                if task.respond_to?(:plan)
                    if !task.plan
                        if task.removed_at
                            raise InternalError, "#{task}, which has been selected for #{key}, has been removed from its plan\n  Removed at\n    #{task.removed_at.join("\n    ")}"
                        else
                            raise InternalError, "#{task}, which has been selected for #{key}, is not included in any plan"
                        end
                    elsif !(task.plan == engine.plan)
                        raise InternalError, "#{task}, which has been selected for #{key}, is not in #{engine.plan} (is in #{task.plan})"
                    end
                end
            end

            # Create a concrete task for this requirements
            def instanciate(engine)
                selection = engine.main_selection.merge(using_spec)
                selection.each_key do |key|
                    if result = resolve_explicit_selection(selection[key])
                        verify_result_in_transaction(key, result)
                        selection[key] = result
                    end
                end

                @task = model.instanciate(engine, arguments.merge(:selection => selection))
            end
        end

        # The main deployment algorithm
        #
        # Engine instances are the objects that actually get deployment
        # requirements and produce a deployment, possibly dynamically.
        #
        # The main entry point for the algorithm is Engine#resolve
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

            ##
            # :method: dry_run?
            #
            # If true, the resulting tasks are all set as being non-executable,
            # so that they don't get started

            ##
            # :method: dry_run=
            #
            # Set the dry_run predicate to the given value. See dry_run?
            attr_predicate :dry_run, true

	    ##
	    # :method: disabled?
	    #
	    # Completely disable #resolve. This can be used to make sure that
	    # the engine will not touch the plan
	    #
	    # Set with disable_updates and reset with enable_updates
	    attr_predicate :disabled?

	    # Set the disabled flag
	    #
	    # See #disabled?
	    def disable_updates; @disabled = true end

	    # Resets the disabled flag
	    #
	    # See #disabled?
	    def enable_updates; @enabled = true end

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # The following options are allowed:
            # on::
            #   if given, it is the name of a process server as declared with
            #   Application#orocos_process_server. The deployment will be
            #   started only on that process server. It defaults to "localhost"
            #   (i.e., the local machine)
            def use_deployment(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server = process_server_for(options[:on])
                deployer = server.load_orogen_deployment(name)
                deployments[options[:on]] << name
                self
            end

            # Returns the process server object named +name+
            def process_server_for(name)
                server = RobyPlugin.process_servers[name]
                if !server
                    if name == 'localhost'
                        return Roby.app.main_orogen_project
                    end
                    raise ArgumentError, "there is no registered process server called #{name}"
                end
                server.first
            end

            # Add all the deployments defined in the given oroGen project to the
            # set of deployments that the engine can use.
            #
            # See #use_deployment
            def use_deployments_from(project_name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server = process_server_for(options[:on])
                orogen = server.load_orogen_project(project_name)
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install?
                        use_deployment(deployment_def.name, options)
                    end
                end
                self
            end

            # Describes the robot. Example:
            #
            #   robot do
            #       device 'device_type'
            #       device 'device_name', :type => 'device_type'
            #   end
            #
            def robot(&block)
                if block_given?
                    @robot.with_module(*RobyPlugin.constant_search_path, &block)
                end
                @robot
            end

            # :method: modified?
            #
            # True if the requirements changed since the last call to #resolve
            attr_predicate :modified

            # Force marking the specification as modified, triggering a system
            # update
            def modified!
                @modified = true
            end

            def initialize(plan, model, robot = nil)
                @plan      = plan
                @model     = model
                @robot     = robot || RobotDefinition.new(self)

                @use_main_selection = true
                @service_allocation_candidates = Hash.new

                @instances = Array.new
                @tasks     = Hash.new
                @deployments = Hash.new { |h, k| h[k] = Set.new }
                @main_selection = Hash.new
                @main_user_selection = Hash.new
                @defines   = Hash.new
                @modified  = false
                @pending_removes = Hash.new

                @dot_index = 0
            end

            # The set of selections the user specified should be applied on
            # every compositions. See Engine#use and InstanciatedComponent#use
            # for more details on the format
            attr_reader :main_user_selection

            # The system-level device selection used during instanciation
            attr_reader :main_selection

            # Provides system-level selection.
            #
            # This is akin to dependency injection at the system level. See
            # InstanciatedComponent#use for details.
            def use(mappings)
                mappings.each do |model, definition|
                    main_user_selection[model] = definition
                end
            end

            # Require a new composition/service, and specify that it should be
            # marked as 'mission' in the plan manager
            def add_mission(*args)
                instance = add(*args)
                instance.mission = true
                instance
            end

            # Helper method that creates an instance of InstanciatedComponent
            # and registers it
            def create_instanciated_component(model, arguments = Hash.new) # :nodoc:
                if !model.kind_of?(MasterDeviceInstance) && !(model.kind_of?(Class) && model < Component)
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
                arguments, task_arguments = Kernel.filter_options arguments, :as => nil
                instance = InstanciatedComponent.new(self, arguments[:as], model, task_arguments)
            end

            # Define a component instanciation specification, without adding it
            # to the current deployment.
            #
            # The definition can later be used in #add:
            #
            #   define 'piv_control', Control,
            #       'control' => PIVController::Task
            #
            #   ...
            #   add 'piv_control'
            def define(name, model, arguments = Hash.new)
                # Set the name to 'name' by default, unless the user provided an
                # 'as' argument explicitely
                name_arg, _ = Kernel.filter_options arguments.dup, :as => nil
                if !name_arg.has_key?(:name)
                    arguments[:as] = name
                end
                defines[name] = create_instanciated_component(model, arguments)
            end

            # Add a new component requirement to the current deployment
            #
            # +model+ can either be the name of a definition (see Engine#define)
            # or a component model.
            #
            # +arguments+ is a hash that can contain explicit child selection
            # specification (if +model+ is a composition).
            def add(model, arguments = Hash.new)
                if model.respond_to?(:to_str)
                    if device = instance = robot.devices[model.to_str]
                        instance = create_instanciated_component(device, arguments)
                    elsif !(instance = defines[model.to_str])
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

            # Replace all running services that fullfill +model+ by the +name+
            # definition (added with #define). If none is running, +name+ is
            # simply added
            def set(model, name)
                begin
                    remove(model)
                rescue ArgumentError
                end

                add(name)
            end

            # Replaces a task already in the deployment by a new task
            #
            # +current_task+ can either be the Roby::Task (from the plan
            # manager's plan) or the value returned by #add
            def replace(current_task, new_task, arguments = Hash.new)
                if current_task.respond_to?(:task)
                    current_task = current_task.task
                end

                task = add(new_task, arguments)
                task.replaces = current_task

                if current_task
                    instances.delete_if do |instance|
                        instance.task == current_task
                    end
                end
                task
            end

            # The set of instances that should be removed at the next call to
            # #resolve
            #
            # It is a mapping from the instance object to a boolean. The boolean
            # tells the engine whether the remove should be retried even if the
            # resolve failed (true) or not (false)
            attr_reader :pending_removes

            # Removes a task from the current deployment
            #
            # +task+ can be:
            # 
            # * the value returned by #add
            # * the Roby::Task instance from the plan manager
            # * the task name as given to #add through the :as option
            # * a task model, in which case all components that match this model
            #   will be removed
            def remove(task, force = false)
                if task.kind_of?(InstanciatedComponent)
                    removed_instances = instances.find_all { |t| t == task }
                elsif task.kind_of?(Roby::Task)
                    removed_instances = instances.find_all { |t| t.task == task }
                    if removed_instances.empty?
                        raise ArgumentError, "#{task} has not been added through Engine#add"
                    end
                elsif task.respond_to?(:to_str)
                    removed_instances = instances.find_all { |t| t.name == task.to_str }
                    if removed_instances.empty?
                        raise ArgumentError, "no task called #{task} has been instanciated through Engine#add"
                    end
                elsif task < Roby::Task || task.kind_of?(Roby::TaskModelTag)
                    removed_instances = instances.find_all do |t|
                        model =
                            if t.model.kind_of?(MasterDeviceInstance)
                                t.model.task_model
                            else
                                t.model
                            end
                        model <= task
                    end
                    if removed_instances.empty?
                        raise ArgumentError, "no task matching #{task} have been instanciated through Engine#add"
                    end
                end

                @modified = true
                removed_instances.each do |instance|
		    Engine.debug { "queueing removal of #{instance.task}" }
                    pending_removes[instance] = force
                end
            end

            # Called when the plan manager has garbage-collected a task that was
            # under this engine's control. The difference with #remove is that
            # it does not trigger a resolution pass -- since the task and its
            # dependencies are already being removed from the plan anyway.
            def removed(task)
                modified = @modified
                remove(task, true)
                @modified = modified
            end

            # Register the given task and all its services in the +tasks+ hash
            def register_task(name, task)
                tasks[name] = task
                task.model.each_data_service do |_, srv|
                    tasks["#{name}.#{srv.full_name}"] = task
                    if !srv.master? && srv.master.main?
                        tasks["#{name}.#{srv.name}"] = task
                    end
                end
            end

            # Internal class used to backup the engine's state in #resolve, so
            # that we are able to rollback in  case the deployment fails.
            class StateBackup
                attr_accessor :device_tasks
                attr_accessor :instance_tasks
                attr_accessor :instances
                def valid?; @valid end
                def valid!; @valid = true end

                def initialize
                    @device_tasks = Hash.new
                    @instance_tasks = Hash.new
                    @instances = Hash.new
                end
            end

            # Remove everything that is currently added to the system
            def clear
	        instances.clear
	    end

	    def remove_all
                instances.each do |instance|
                    pending_removes[instance] = false
                end
                @modified = true
            end

            # Create the task instances that are currently required by the
            # deployment specification
            #
            # It does not try to merge the result, i.e. after #instanciate the
            # plan is probably full of abstract tasks.
            def instanciate
                self.tasks.clear

                Orocos::RobyPlugin::Compositions.each do |composition_model|
                    composition_model.reset_autoconnection
                end

                robot.each_master_device do |name, device_instance|
                    task =
                        if device_instance.task && device_instance.task.plan == plan.real_plan && !device_instance.task.finished?
                            device_instance.task
                        else
                            device_instance.instanciate(self)
                        end

                    # Wrap it if it is already in the main plan
                    task = plan[task]
                    # Register it
                    device_instance.task = task
                    register_task(name, task)
                end


                instances.each do |instance|
                    instance.task = nil
                end

                instances.each do |instance|
                    task =
                        if instance.model.kind_of?(MasterDeviceInstance)
                            instance.model.task
                        else
                            instance.instanciate(self)
                        end
                    instance.task = plan[task]

                    if name = instance.name
                        register_task(name, task)
                    end

                    if instance.mission?
                        plan.add_mission(task)
                    else
                        # This is important here, as #resolve uses
                        # static_garbage_collect to clear up the plan
                        #
                        # However, the permanent flag will be removed at the end
                        # of #resolve
                        plan.add_permanent(task)
                    end
                end
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                # For backward compatibility reasons
                if !filename
                    filename = kind
                    kind = 'dataflow'
                end

                Tempfile.open('roby_orocos_deployment') do |io|
                    io.write send("to_dot_#{kind}", *additional_args)
                    io.flush

                    File.open(filename, 'w') do |output_io|
                        output_io.puts(`dot -Tsvg #{io.path}`)
                    end
                end
            end

            # Generates a dot graph that represents the task hierarchy in this
            # deployment
            def to_dot_hierarchy
                result = []
                result << "digraph {"
                result << "  rankdir=TB"
                result << "  node [shape=record,height=.1,fontname=\"Arial\"];"

                all_tasks = ValueSet.new

                plan.find_local_tasks(Composition).each do |task|
                    all_tasks << task
                    task.each_child do |child_task, _|
                        all_tasks << child_task
                        result << "  #{task.dot_id} -> #{child_task.dot_id};"
                    end
                end

                plan.find_local_tasks(Deployment).each do |task|
                    all_tasks << task
                    task.each_executed_task do |component|
                        all_tasks << component
                        result << "  #{component.dot_id} -> #{task.dot_id} [color=\"blue\"];"
                    end
                end

                all_tasks.each do |task|
                    task_label, attributes = format_task_label(task)
                    attributes << "label=<#{task_label}>"
                    if task.abstract?
                        attributes << " color=\"red\""
                    end

                    result << "  #{task.dot_id} [#{attributes.join(" ")}];"
                end

                result << "};"
                result.join("\n")
            end

            def to_dot
                to_dot_dataflow
            end

            # Generates a dot graph that represents the task dataflow in this
            # deployment
            def to_dot_dataflow(remove_compositions = false)
                result = []
                result << "digraph {"
                result << "  rankdir=LR"
                result << "  node [shape=none,margin=0,height=.1,fontname=\"Arial\"];"

                output_ports = Hash.new { |h, k| h[k] = Set.new }
                input_ports  = Hash.new { |h, k| h[k] = Set.new }

                all_tasks = plan.find_local_tasks(Deployment).to_value_set

                plan.find_local_tasks(Component).each do |source_task|
                    next if remove_compositions && source_task.kind_of?(Composition)

                    source_task.model.each_input_port do |port|
                        input_ports[source_task] << port.name
                    end
                    source_task.model.each_output_port do |port|
                        output_ports[source_task] << port.name
                    end
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

                            result << "  #{source_task.dot_id}:#{source_port} -> #{sink_task.dot_id}:#{sink_port} [label=\"#{policy_s}\"];"
                        end
                    end

                    if !remove_compositions
                        source_task.each_sink do |sink_task, connections|
                            next if !sink_task.kind_of?(Composition) && !source_task.kind_of?(Composition)
                            connections.each do |(source_port, sink_port), _|
                                output_ports[source_task] << source_port
                                input_ports[sink_task]    << sink_port

                                result << "  #{source_task.dot_id}:#{source_port} -> #{sink_task.dot_id}:#{sink_port} [style=dashed];"
                            end
                        end
                    end
                end

                clusters = Hash.new { |h, k| h[k] = Array.new }
                all_tasks.each do |task|
                    if !task.kind_of?(Deployment)
                        clusters[task.execution_agent] << task
                    end
                end

                # Allocate one color for each task. The ideal would be to do a
                # graph coloring so that two related tasks don't get the same
                # color, but that's TODO
                task_colors = Hash.new
                used_deployments = all_tasks.map(&:execution_agent).to_value_set
                used_deployments.each do |task|
                    task_colors[task] = RobyPlugin.allocate_color
                end

                clusters.each do |deployment, task_contexts|
                    if deployment
                        result << "  subgraph cluster_#{deployment.dot_id} {"
                        result << "    #{dot_task_attributes(deployment, Array.new, Array.new, task_colors, remove_compositions).join(";\n     ")};"
                    end

                    task_contexts.each do |task|
                        if !task
                            raise "#{task} #{deployment} #{task_contexts.inspect}"
                        end
                        attributes = dot_task_attributes(task, input_ports[task].to_a.sort, output_ports[task].to_a.sort, task_colors, remove_compositions)
                        result << "    #{task.dot_id} [#{attributes.join(",")}];"
                    end

                    if deployment
                        result << "  };"
                    end
                end

                result << "};"
                result.join("\n")
            end

            def format_task_label(task, task_colors = Hash.new)
                task_node_attributes = []
                task_flags = []
                #task_flags << "E" if task.executable?
                #task_flags << "A" if task.abstract?
                #task_flags << "C" if task.kind_of?(Composition)
                task_flags =
                    if !task_flags.empty?
                        "[#{task_flags.join(",")}]"
                    else ""
                    end
                
                task_label = 
                    if task.respond_to?(:proxied_data_services)
                        task.proxied_data_services.map(&:model).map(&:short_name).join(", ") + task_flags
                    else
                        text = task.to_s
                        text = text.gsub('Orocos::RobyPlugin::', '').
                            gsub(/\s+/, '').gsub('=>', ':').tr('<>', '[]')
                        result =
                            if text =~ /(.*)\/\[(.*)\](:0x[0-9a-f]+)/
                                # It is a specialization, move the
                                # specialization specification below the model
                                # name
                                name = $1
                                specializations = $2
                                id  = $3
                                name + task_flags +
                                    "<BR/>" + specializations.gsub('),', ')<BR/>')
                            else
                                text.gsub /:0x[0-9a-f]+/, ''
                            end
                        result.gsub(/\s+/, '').gsub('=>', ':').
                            gsub(/\[\]|\{\}/, '').gsub(/[{}]/, '<BR/>')
                    end
                task_label.tr('<>', '[]')

                if task.kind_of?(Deployment)
                    if task_colors[task]
                        task_node_attributes << "color=\"#{task_colors[task]}\""
                        task_label = "<FONT COLOR=\"#{task_colors[task]}\">#{task_label}"
                        task_label << " <BR/> [Process name: #{task.model.deployment_name}]</FONT>"
                    else
                        task_label = "#{task_label}"
                        task_label << " <BR/> [Process name: #{task.model.deployment_name}]"
                    end
                end

                return task_label, task_node_attributes
            end

            # Helper method for the to_dot methods
            def dot_task_attributes(task, inputs, outputs, task_colors, remove_compositions = false) # :nodoc:
                task_label, task_dot_attributes = format_task_label(task, task_colors)

                label = "  <TABLE ALIGN=\"LEFT\" BORDER=\"0\" CELLBORDER=\"#{task.kind_of?(Deployment) ? '0' : '1'}\" CELLSPACING=\"0\">\n"
                if !inputs.empty?
                    label << inputs.map do |name|
                        "    <TR><TD PORT=\"#{name}\">#{name} </TD></TR>\n"
                    end.join("")
                end
                label << "    <TR><TD ALIGN=\"LEFT\" PORT=\"main\">#{task_label} </TD></TR>\n"
                if !outputs.empty?
                    label << outputs.map do |name|
                        "    <TR><TD PORT=\"#{name}\">#{name} </TD></TR>\n"
                    end.join("")
                end
                label << "  </TABLE>"

                task_dot_attributes << "label=< #{label} >"
                if task.abstract?
                    task_dot_attributes << "color=\"red\""
                end
                task_dot_attributes
            end

            def pretty_print(pp) # :nodoc:
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

            def validate_generated_network(plan, options = Hash.new)
                # Check for the presence of abstract tasks
                still_abstract = plan.find_local_tasks(Component).
                    abstract.to_a

                if !still_abstract.empty?
                    raise TaskAllocationFailed.new(still_abstract),
                        "could not find implementation for the following abstract tasks: #{still_abstract}"
                end
            end

            def validate_final_network(plan, options = Hash.new)
                # Check that all device instances are proper tasks (not proxies)
                instances.each do |instance|
                    if instance.task.transaction_proxy?
                        raise InternalError, "some transaction proxies are stored in instance definitions"
                    end
                end
                robot.devices.each do |name, instance|
                    if instance.task.transaction_proxy?
                        raise InternalError, "some transaction proxies are stored in devices definitions"
                    end
                end

                if options[:compute_deployments]
                    # Check for the presence of non-deployed tasks
                    not_deployed = plan.find_local_tasks(TaskContext).
                        find_all { |t| !t.execution_agent }.
                        delete_if do |p|
                            p.parent_objects(Roby::TaskStructure::Dependency).to_a.empty?
                        end

                    if !not_deployed.empty?
                        raise MissingDeployments.new(not_deployed),
                            "there are tasks for which it exists no deployed equivalent: #{not_deployed.map(&:to_s)}"
                    end
                end
            end

            # A mapping from data service models to concrete models
            # (compositions and/or task models) that implement it
            attr_reader :service_allocation_candidates

            # If true, the engine will compute for each service the set of
            # concrete task models that provides it. If that set is one element,
            # it will automatically add it to the set of default selection.
            #
            # If false, this mechanism is ignored
            #
            # It is true by default
            attr_predicate :use_main_selection?, true

            # Must be called everytime the system model changes. It updates the
            # values that are cached to speed up the instanciation process
            def prepare
                # This caches the mapping from child name to child model to
                # speed up instanciation
                model.each_composition do |composition|
                    composition.update_all_children
                end

                # We now compute default selections for data service models. It
                # computes if there is only one non-abstract task model that
                # provides a given data service, and -- if it is the case --
                # will add it to the 'use' sets
                all_concrete_models = ValueSet.new
                all_models = ValueSet.new
                model.each_composition do |composition_model|
                    if !composition_model.abstract?
                        all_concrete_models << composition_model 
                    end
                    all_models << composition_model
                end
                model.each_task_model do |task_model|
                    if !task_model.abstract?
                        all_concrete_models << task_model
                    end
                    all_models << task_model
                end

                service_allocation_candidates.clear
                result = Hash.new
                model.each_data_service do |service|
                    candidates = all_concrete_models.
                        find_all { |m| m.fullfills?(service) }
                    if candidates.size == 1
                        result[service] = candidates.to_a.first
                    end

                    candidates = all_models.find_all do |m|
                        m.fullfills?(service)
                    end
                    if !candidates.empty?
                        service_allocation_candidates[service] = candidates
                    end
                end

                if !use_main_selection?
                    @main_selection = main_user_selection.dup
                else
                    @main_selection = result.merge(main_user_selection)
                end
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network
                instanciate

                # Needed at least for now to merge together drivers that
                # have multiple devices
                @network_merge_solver.merge_identical_tasks
                link_to_busses
                @network_merge_solver.merge_identical_tasks
            end

            # Hook called by the merge algorithm
            #
            # It updates the +tasks+, robot.devices 'task' attribute and
            # instances hashes
            def merged_tasks(merges)
                tasks.each_key do |n|
                    if task = merges[tasks[n]]
                        tasks[n] = task
                        if robot.devices[n] && robot.devices[n].respond_to?(:task=)
                            robot.devices[n].task = task
                        end
                    end
                end
                instances.each do |i|
                    if task = merges[i.task]
                        i.task = task
                    end
                end
            end

            # Generate the deployment according to the current requirements, and
            # merges it into the current plan
            #
            # The following options are understood:
            #
            # compute_policies::
            #   if false, it will not compute the policies between ports. Mainly
            #   useful for offline testing
            # compute_deployments::
            #   if false, it will not do the deployment allocation. Mainly
            #   useful for testing/debugging purposes. It obviously turns off
            #   the policy computation as well.
            # garbage_collect::
            #   if false, it will not clean up the plan from all tasks that are
            #   not useful. Mainly useful for testing/debugging purposes
            # export_plan_on_error::
            #   by default, #resolve will generate a dot file containing the
            #   current plan state if an error occurs. Set this option to false
            #   to disable this (it is costly).
            def resolve(options = Hash.new)
	    	return if disabled?

                if options == true
                    options = { :compute_policies => true }
                end
                options = Kernel.validate_options options,
                    :compute_policies    => true,
                    :compute_deployments => true,
                    :garbage_collect => true,
                    :export_plan_on_error => true,
                    :save_plans => false,
                    :validate_network => true,
                    :forced_removes => false # internal flag

                # It makes no sense to compute the policies if we are not
                # computing the deployments, as policy computation needs
                # deployment information
                if !options[:compute_deployments]
                    options[:compute_policies] = false
                end

                prepare

                # Start by applying pending modifications, and saving the
                # current instanciation state in case we need to discard the
                # modifications (because of an error)
                state_backup = StateBackup.new
                robot.each_master_device do |name, device_instance|
                    state_backup.device_tasks[name] = device_instance.task
                end
                state_backup.instances = instances.dup
                instances.each do |instance|
                    state_backup.instance_tasks[instance] = instance.task
                end
                state_backup.valid!

                engine_plan = @plan
                plan.in_transaction do |trsc|
                    @network_merge_solver = NetworkMergeSolver.new(trsc, &method(:merged_tasks))

                    begin
                    @plan = trsc

                    deleted_tasks = ValueSet.new
                    instances.delete_if do |instance|
                        if (pending_removes.has_key?(instance.task) || pending_removes.has_key?(instance))
                            deleted_tasks << instance.task if instance.task && instance.task.plan
                            true
                        else
                            false
                        end
                    end

                    compute_system_network

                    used_tasks = trsc.find_local_tasks(Component).
                        to_value_set

                    # This must be done *after* #compute_system_network,
                    # and the computation of #used_tasks otherwise the deleted
                    # tasks will end up in used_tasks
                    deleted_tasks = deleted_tasks.map do |task|
		        Engine.debug { "removed #{task}, removing mission and/or permanent" }
                        task = plan[task]
                        plan.unmark_mission(task)
                        plan.unmark_permanent(task)
                        task.remove_relations(Orocos::RobyPlugin::Flows::DataFlow)
                        task
                    end.to_value_set

                    all_tasks = trsc.find_tasks(Component).to_value_set
                    all_tasks.delete_if do |t|
                        if t.finishing? || t.finished?
                            Engine.debug { "clearing the relations of the finished task #{t}" }
                            t.remove_relations(Orocos::RobyPlugin::Flows::DataFlow)
                            t.remove_relations(Roby::TaskStructure::Dependency)
                            true
                        elsif t.transaction_proxy?
                            # Check if the task is a placeholder for a
                            # requirement modification
                            planner = t.__getobj__.planning_task
                            if planner.kind_of?(RequirementModificationTask) && !planner.finished?
                                trsc.remove_object(t)
                                true
                            end
                        end
                    end

                    (all_tasks - used_tasks).each do |t|
                        Engine.debug { "clearing the relations of #{t}" }
                        t.remove_relations(Orocos::RobyPlugin::Flows::DataFlow)
                    end

                    if options[:garbage_collect]
                        trsc.static_garbage_collect do |obj|
                            if obj.transaction_proxy?
                                # Clear up the dependency relations for the
                                # obsolete tasks that are in the plan
                                obj.remove_relations(Roby::TaskStructure::Dependency)
                            else
                                # Remove tasks that we just added and are not
                                # useful anymore
                                trsc.remove_object(obj)
                            end
                        end
                    end

                    if options[:garbage_collect] && options[:validate_network]
                        validate_generated_network(trsc, options)
                    end

                    if options[:compute_deployments]
                        instanciate_required_deployments
                        @network_merge_solver.merge_identical_tasks
                    end

                    # the tasks[] and devices mappings are updated during the
                    # merge. We replace the proxies by the corresponding tasks
                    # when applicable
                    instances.each do |instance|
                        if instance.task && instance.task.transaction_proxy?
                            instance.task = instance.task.__getobj__
                        end
                    end
                    robot.devices.keys.each do |name|
                        device_task = robot.devices[name].task
                        if device_task.plan == trsc && device_task.transaction_proxy?
                            if device_task.__getobj__
                                robot.devices[name].task = device_task.__getobj__
                            else # unused
                                robot.devices.delete(name)
                            end
                        end
                    end
                    tasks.each_key do |name|
                        next if !robot.devices[name]
                        instance_task = robot.devices[name].task
                        if instance_task.plan == trsc && instance_task.transaction_proxy?
                            tasks[name].task = instance_task.__getobj__
                        end
                    end

                    # Finally, we should now only have deployed tasks. Verify it
                    # and compute the connection policies
                    if options[:garbage_collect] && options[:validate_network]
                        validate_final_network(trsc, options)
                    end

                    if options[:compute_policies]
                        DataFlowDynamics.compute_connection_policies(plan)
                    end

                    if options[:garbage_collect]
                        trsc.static_garbage_collect do |obj|
                            if obj.transaction_proxy?
                                # Clear up the dependency relations for the
                                # obsolete tasks that are in the plan
                                obj.remove_relations(Roby::TaskStructure::Dependency)
                            else
                                # Remove tasks that we just added and are not
                                # useful anymore
                                trsc.remove_object(obj)
                            end
                        end
                    end

                    # Remove the permanent flag from all the new tasks. We
                    # originally mark them as permanent to protect them from
                    # #static_garbage_collect
                    plan.find_tasks.permanent.each do |t|
                        if !t.transaction_proxy? && plan.permanent?(t)
                            plan.unmark_permanent(t)
                        end
                    end

                    if dry_run?
                        trsc.find_local_tasks(Component).
                            each do |task|
                                next if task.running?
                                if task.kind_of?(TaskContext)
                                    task.executable = false
                                end
                            end
                    end

                    if options[:save_plans]
                        output_path = autosave_plan_to_dot
                        Engine.info "saved generated plan into #{output_path}"
                    end
                    trsc.commit_transaction
                    pending_removes.clear
                    @modified = false

                    rescue Exception => e
                        if options[:export_plan_on_error]
                            Roby.log_pp(e, Roby, :fatal)
                            Engine.fatal "Engine#resolve failed"
                            output_path = autosave_plan_to_dot
                            Engine.fatal "the generated plan has been saved into #{output_path}"
                            Engine.fatal "use dot -Tsvg #{output_path} > #{output_path}.svg to convert to SVG"
                        end
                        raise
                    end
                end

            rescue Exception => e
                @plan = engine_plan

                if !state_backup || (state_backup && !state_backup.valid?)
                    # We might have done something, we just don't know
                    # what and can't rollback.
                    #
                    # Just announce to Roby that something critical
                    # happened
                    pending_removes.clear
                    Roby.engine.add_framework_error(e, "orocos-engine-resolve")
                    raise e
                end

                # We can rollback. We just do it, and then raise the
                # error again. The update handler should propagate the
                # error to the requirement modification tasks
                state_backup.device_tasks.each do |name, task|
                    robot.devices[name].task = task
                end
                @instances = state_backup.instances
                instances.each do |instance|
                    instance.task = state_backup.instance_tasks.delete(instance)
                end
                @modified = false

                Engine.fatal "Engine#resolve failed and rolled back"

                if !options[:forced_removes]
                    Engine.fatal "Retrying to remove obsolete tasks ..."
                    pending_removes.delete_if { |_, force| !force }
                    if !pending_removes.empty?
                        resolve(options.merge(:forced_removes => true))
                    end
                end

                raise

            ensure
                @plan = engine_plan
            end

            def autosave_plan_to_dot(suffix = nil)
                output_path = File.join(Roby.app.log_dir, "orocos-engine-plan-#{(suffix + '-') if suffix}#{@dot_index}.dot")
                @dot_index += 1
                File.open(output_path, 'w') do |io|
                    io.write to_dot
                end
                output_path
            end

            def link_task_to_bus(task, bus_name)
                if !(com_bus_task = tasks[bus_name])
                    raise SpecError, "there is no task that handles a communication bus named #{bus_name}"
                end
                # Assume that if the com bus is one of our dependencies,
                # then it means we are already linked to it
                return if task.depends_on?(com_bus_task)

                if !(com_bus = robot.com_busses[bus_name])
                    raise SpecError, "there is no communication bus named #{bus_name}"
                end

                # Enumerate in/out ports on task of the bus datatype
                message_type = Orocos.registry.get(com_bus.model.message_type).name
                out_candidates = task.model.each_output_port.find_all do |p|
                    p.type.name == message_type
                end
                in_candidates = task.model.each_input_port.find_all do |p|
                    p.type.name == message_type
                end
                if out_candidates.empty? && in_candidates.empty?
                    raise SpecError, "#{task} is supposed to be connected to #{bus_name}, but #{task.model.name} has no ports of type #{message_type} that would allow to connect to it"
                end

                task.depends_on com_bus_task

                com_bus_in = com_bus_task.model.each_input_port.
                    find_all { |p| p.type.name == message_type }
                com_bus_in =
                    if com_bus_in.size == 1
                        com_bus_in.first.name
                    end

                in_connections  = Hash.new
                out_connections = Hash.new
                handled    = Hash.new
                used_ports = Set.new

                task.model.each_root_data_service do |source_name, source_service|
                    source_model = source_service.model
                    next if !(source_model < DataSource)
                    device_spec = robot.devices[task.arguments["#{source_name}_name"]]
                    next if !device_spec || !device_spec.com_bus_names.include?(bus_name)
                    
                    in_ports  = in_candidates.
                        find_all { |p| p.name =~ /#{source_name}/i }
                    out_ports = out_candidates.
                        find_all { |p| p.name =~ /#{source_name}/i }

                    if in_ports.size > 1
                        raise Ambiguous, "there are multiple options to connect #{bus_name} to #{source_name} in #{task}: #{in_ports.map(&:name)}"
                    elsif out_ports.size > 1
                        raise Ambiguous, "there are multiple options to connect #{source_name} in #{task} to #{bus_name}: #{out_ports.map(&:name)}"
                    end

                    handled[source_name] = [!out_ports.empty?, !in_ports.empty?]
                    if !in_ports.empty?
                        port = in_ports.first
                        used_ports << port.name
                        com_out_port = com_bus.model.output_name_for(source_name)
                        com_bus_task.port_to_device[com_out_port] << device_spec.name
                        in_connections[ [com_out_port, port.name] ] = Hash.new
                    end
                    if !out_ports.empty?
                        port = out_ports.first
                        used_ports << port.name
                        com_in_port = com_bus_in || com_bus.model.input_name_for(source_name)
                        com_bus_task.port_to_device[com_in_port] << device_spec.name
                        out_connections[ [port.name, com_in_port] ] = Hash.new
                    end
                end

                # if there are some unconnected data sources, search for
                # generic ports (input and/or output) on the task, and link
                # to it.
                if handled.values.any? { |v| v == [false, false] }
                    generic_name = handled.find_all { |_, v| v == [false, false] }.
                        map(&:first).join("_")
                    in_candidates.delete_if  { |p| used_ports.include?(p.name) }
                    out_candidates.delete_if { |p| used_ports.include?(p.name) }

                    if in_candidates.size > 1
                        raise Ambiguous, "could not find a connection to the bus #{bus_name} for the input ports #{in_candidates.map(&:name).join(", ")} of #{task}"
                    elsif in_candidates.size == 1
                        com_out_port = com_bus.model.output_name_for(generic_name)
                        task.each_device do |service, device|
                            if device.attached_to?(bus_name)
                                com_bus_task.port_to_device[com_out_port] << device.name
                            end
                        end
                        in_connections[ [com_out_port, in_candidates.first.name] ] = Hash.new
                    end

                    if out_candidates.size > 1
                        raise Ambiguous, "could not find a connection to the bus #{bus_name} for the output ports #{out_candidates.map(&:name).join(", ")} of #{task}"
                    elsif out_candidates.size == 1
                        # One generic output port
                        com_in_port = com_bus_in || com_bus.model.input_name_for(generic_name)
                        task.each_device do |service, device|
                            if device.attached_to?(bus_name)
                                com_bus_task.port_to_device[com_in_port] << device.name
                            end
                        end
                        out_connections[ [out_candidates.first.name, com_in_port] ] = Hash.new
                    end
                end
                
                if !in_connections.empty?
                    com_bus_task.connect_ports(task, in_connections)
                end
                if !out_connections.empty?
                    task.connect_ports(com_bus_task, out_connections)
                end

                # If the combus model asks us to do it, make sure all
                # connections will be computed as "reliable"
                if com_bus.model.override_policy?
                    in_connections.each_key do |_, sink_port|
                        task.find_input_port_model(sink_port).
                            needs_reliable_connection
                    end
                    out_connections.each_key do |_, sink_port|
                        com_bus_task.find_input_port_model(sink_port).
                            needs_reliable_connection
                    end
                end
            end

            # Creates communication busses and links the tasks to them
            def link_to_busses
                # Get all the tasks that need at least one communication bus
                candidates = plan.find_local_tasks(Orocos::RobyPlugin::DataSource).
                    inject(Hash.new) do |h, t|
                        required_busses = t.com_busses
                        if !required_busses.empty?
                            h[t] = required_busses
                        end
                        h
                    end

                candidates.each do |task, needed_busses|
                    needed_busses.each do |bus_name|
                        link_task_to_bus(task, bus_name)
                    end
                end
                nil
            end

            # Returns true if +deployed_task+ should be completely ignored by
            # the engine when deployed tasks are injected into the system
            # deployer
            #
            # For now, the logger is hardcoded there
            def ignored_deployed_task?(deployed_task)
                Roby.app.orocos_tasks[deployed_task.task_model.name].name == "Orocos::RobyPlugin::Logger::Logger"
            end

            # Instanciates all deployments that have been specified by the user.
            # Reuses deployments in the current plan manager's plan if possible
            def instanciate_required_deployments
                Engine.debug do
                    Engine.debug ""
                    Engine.debug "----------------------------------------------------"
                    Engine.debug "Instanciating deployments"
                    break
                end

                deployments.each do |machine_name, deployment_names|
                    deployment_names.each do |deployment_name|
                        model = Roby.app.orocos_deployments[deployment_name]

                        task  = plan.find_tasks(model).
                            find { |t| t.arguments[:on] == machine_name }
                        task ||= model.new(:on => machine_name)
                        task.robot = robot
                        plan.add(task)

                        new_activities = Set.new
                        task.orogen_spec.task_activities.each do |deployed_task|
                            if ignored_deployed_task?(deployed_task)
                                Engine.debug { "ignoring #{deployment_name}.#{deployed_task.name} as it is of type #{deployed_task.task_model.name}" }
                            else
                                new_activities << deployed_task.name
                            end
                        end

                        task.merged_relations(:each_executed_task, true).each do |t|
                            if !t.finishing? && !t.finished?
                                new_activities.delete(t.orocos_name)
                            end
                        end

                        new_activities.each do |act_name|
                            new_task = task.task(act_name)
                            deployed_task = plan[new_task]
                            Engine.debug do
                                "  #{deployed_task.orogen_name} on #{task.deployment_name}[machine=#{task.machine}] is represented by #{deployed_task}"
                            end
                        end
                    end
                end
                Engine.debug do
                    Engine.debug "Done instanciating deployments"
                    Engine.debug "----------------------------------------------------"
                    Engine.debug ""
                    break
                end
            end

            # Load the given DSL file into this Engine instance
            def load(file)
                search_path = [RobyPlugin,
                    RobyPlugin::DataServices,
                    RobyPlugin::DataSources,
                    RobyPlugin::Compositions]

                if Kernel.load_dsl_file(file, self, search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
            end

            # Declare that the services listed in +names+ are available to
            # fullfill the +service+ model.
            #
            # It calls #modality_selection on the MainPlanner. The immediate
            # consequence is that corresponding "modality_name" methods are
            # made available on the planner, and "modality_name!" methods are
            # available on the Roby shell
            def modality_selection(service, *names)
                ::MainPlanner.modality_selection(service, *names)
            end

	    def planner_method(name, &block)
	        ::MainPlanner.method(name, &block)
	    end
        end

        # This method is called at the beginning of each execution cycle, and
        # updates the running TaskContext tasks.
        def self.update(plan) # :nodoc:
            tasks = plan.find_tasks(RequirementModificationTask).running.to_a
            
            if Roby.app.orocos_engine.modified?
                # We assume that all requirement modification have been applied
                # by the RequirementModificationTask instances. They therefore
                # take the blame if something fails, and announce a success
                begin
                    Roby.app.orocos_engine.resolve
                    tasks.each do |t|
                        t.emit :success
                    end
                rescue Exception => e
                    if tasks.empty?
                        # No task to take the blame ... we'll have to shut down
                        raise 
                    end
                    tasks.each do |t|
                        t.emit(:failed, e)
                    end
                end
            end

            all_dead_deployments = ValueSet.new
            for name, server in Orocos::RobyPlugin.process_servers
                server = server.first
                if dead_deployments = server.wait_termination(0)
                    dead_deployments.each do |p, exit_status|
                        d = Deployment.all_deployments[p]
                        if !d.finishing?
                            Orocos::RobyPlugin.warn "#{p.name} unexpectedly died on #{name}"
                        end
                        all_dead_deployments << d
                        d.dead!(exit_status)
                    end
                end
            end

            for deployment in all_dead_deployments
                deployment.cleanup_dead_connections
            end

            if !(query = plan.instance_variable_get :@orocos_update_query)
                query = plan.find_tasks(Orocos::RobyPlugin::TaskContext).
                    not_finished.not_failed
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                next if !t.orogen_task
                # Some CORBA implementations (namely, omniORB) may behave weird
                # if the remote process terminates in the middle of a remote
                # call.
                #
                # Ignore tasks whose process is terminating to reduce the
                # likelihood of that happening
		if t.execution_agent.ready_to_die?
		    next
		end

                if !t.setup? 
                    if t.ready_for_setup? && Roby.app.orocos_auto_configure?
                        begin
                            t.setup 
                        rescue Exception => e
                            t.event(:start).emit_failed(e)
                        end
                        next
                    end
                end

                handled_this_cycle = Array.new
                next if !t.running?

                begin
                    while t.update_orogen_state
                        state = t.orogen_state

                        # Returns nil if we have a communication problem. In this
                        # case, #update_orogen_state will have emitted the right
                        # events for us anyway
                        if state && !handled_this_cycle.include?(state)
                            t.handle_state_changes
                            handled_this_cycle << state
                        end
                    end
                rescue Orocos::CORBA::ComError => e
                    t.emit :aborted, e
                end
            end

            RuntimeConnectionManagement.update(plan, all_dead_deployments)
        end
    end
end


