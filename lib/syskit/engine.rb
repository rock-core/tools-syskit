require 'utilrb/timepoints'
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

        # Extension to the logger's task model for logging configuration
        #
        # It is automatically included in Engine#configure_logging
        module LoggerConfigurationSupport
            attr_reader :logged_ports

            # True if this logger is its deployment's default logger
            #
            # In this case, it will set itself up using the deployment's logging
            # configuration
            attr_predicate :default_logger?, true

            def initialize(arguments = Hash.new)
                super
                @logged_ports = Set.new
            end

            # Wrapper on top of the createLoggingPort operation
            #
            # +sink_port_name+ is the port name of the logging task,
            # +logged_task+ the Orocos::RobyPlugin::TaskContext object from
            # which the data is being logged and +logged_port+ the
            # Orocos::Spec::OutputPort model object of the port that we want to
            # log.
            def createLoggingPort(sink_port_name, logged_task, logged_port)
                return if logged_ports.include?([sink_port_name, logged_port.type.name])

                logged_port_type = logged_port.type.name

                metadata = Hash[
                    'rock_task_model' => logged_task.model.orogen_spec.name,
                    'rock_task_name' => logged_task.orocos_name,
                    'rock_task_object_name' => logged_port.name,
                    'rock_stream_type' => 'port']
                metadata = metadata.map do |k, v|
                    Hash['key' => k, 'value' => v]
                end

                @create_port ||= operation('createLoggingPort')
                if !@create_port.callop(sink_port_name, logged_port_type, metadata)
                    # Look whether a port with that name and type already
                    # exists. If it is the case, it means somebody else already
                    # created it and we're fine- Otherwise, raise an error
                    begin
                        port = input_port(sink_port_name)
                        if port.orocos_type_name != logged_port_type
                            raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}: a port of same name but of type #{port.orocos_type_name} exists"
                        end
                    rescue Orocos::NotFound
                        raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}"
                    end
                end
                logged_ports << [sink_port_name, logged_port_type]
            end

            def configure
                super

                if default_logger?
                    deployment = execution_agent
                    if !deployment.arguments[:log] ||
                        Roby::State.orocos.deployment_excluded_from_log?(deployment)
                        Robot.info "not automatically logging any port in deployment #{name}"
                    else
                        # Only setup the logger
                        deployment.orogen_deployment.setup_logger(
                            :log_dir => deployment.log_dir,
                            :remote => (deployment.machine != 'localhost'))
                    end
                end

                each_input_connection do |source_task, source_port_name, sink_port_name, policy|
                    source_port = source_task.find_output_port_model(source_port_name)
                    createLoggingPort(sink_port_name, source_task, source_port)
                end
            end
        end

        # Represents a requirement created by Engine#add or Engine#define
        class EngineRequirement < InstanceRequirements
            # The name as give  to Engine#add or Engine#define
            attr_accessor :name
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

            def initialize(name, models)
                super(models)
                @name = name
            end
        end

        module PlanExtension
            attr_accessor :orocos_engine
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
            # The model we are working on, as a SystemModel instance
            attr_reader :model
            # The robot on which the software is running
            attr_reader :robot
            # The instances we are supposed to build
            #
            # See #add and #remove
            attr_reader :instances
            # Prepared EngineRequirement instances.
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

                if model = Roby.app.orocos_deployments[name]
                    if deployments[options[:on]].include?(model)
                        return
                    end
                end

                server   = process_server_for(options[:on])
                deployer = server.load_orogen_deployment(name)

                if !Roby.app.loaded_orogen_project?(deployer.project.name)
                    # The project was already loaded on
                    # Orocos.master_project before Roby kicked in. Just load
                    # the Roby part
                    Roby.app.import_orogen_project(deployer.project.name, deployer.project)
                end

                deployer.used_typekits.each do |tk|
                    next if tk.virtual?
                    if Roby.app.orocos_only_load_models?
                        Orocos.load_typekit_registry(tk.name)
                    else
                        Orocos.load_typekit(tk.name)
                    end
                    if server.respond_to?(:preload_typekit)
                        server.preload_typekit(tk.name)
                    end
                end
                deployer.used_task_libraries.each do |lib|
                    Roby.app.using_task_library(lib.name)
                end

                model = Roby.app.orocos_deployments[name]
                deployments[options[:on]] << model
                model
            end

            # Returns the process server object named +name+
            def process_server_for(name)
                server = RobyPlugin.process_servers[name]
                if !server
                    if name == 'localhost' || Roby.app.single?
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

                Orocos::RobyPlugin.info "using deployments from #{project_name}"

                result = []
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install?
                        Orocos::RobyPlugin.info "  #{deployment_def.name}"
                        # Currently, the supervision cannot handle orogen_default tasks 
                        # properly, thus filtering them out for now 
                        if not /^orogen_default/ =~ "#{deployment_def.name}"
                            result << use_deployment(deployment_def.name, options)
                        end
                    end
                end
                result
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
                plan.extend PlanExtension
                plan.orocos_engine = self
                @model     = model
                @robot     = robot || RobotDefinition.new(self)

                @use_main_selection = true
                @service_allocation_candidates = Hash.new

                @instances = Array.new
                @tasks     = Hash.new
                @deployments = Hash.new { |h, k| h[k] = Set.new }
                @main_user_selection = DependencyInjection.new
                @main_automatic_selection = DependencyInjection.new
                @defines   = Hash.new
                @modified  = false
                @pending_removes = Hash.new
            end

            # The set of selections the user specified should be applied on
            # every compositions. See Engine#use and InstanceRequirements#use
            #
            # It is stored as an instance of DependencyInjection
            attr_reader :main_user_selection

            # The set of selections computed based on what is actually available
            # on this system
            #
            # It can be disabled by setting #use_main_selection to false
            attr_reader :main_automatic_selection

            # Provides system-level selection.
            #
            # This is akin to dependency injection at the system level. See
            # EngineRequirement#use for details.
            def use(*mappings)
                main_user_selection.add(*mappings)
            end

            # Require a new composition/service, and specify that it should be
            # marked as 'mission' in the plan manager
            def add_mission(*args)
                instance = add(*args)
                instance.mission = true
                instance
            end

            # Resolve a name into either an InstanceRequirement or an
            # InstanceSelection object, suitable for the instantiation process.
            #
            # The name can refer to an instance definition or to a device.
            # Additionally, a particular service can be selected by using the
            #
            #   base_name.service_name
            #
            # syntax.
            def resolve_name(name, instance_name = nil)
                model_name, *service_name = name.to_str.split('.')
                instance_name = instance_name.to_str if instance_name

                if device = robot.devices[model_name]
                    instance = Engine.create_instanciated_component(self, instance_name, device)
                elsif instance = defines[model_name]
                    instance = instance.dup
                elsif self.model.has_composition?(model_name)
                    component_model = model.composition_model(model_name)
                    instance = Engine.create_instanciated_component(self, instance_name, component_model)
                elsif component_model = Roby.app.orocos_tasks[model_name]
                    instance = Engine.create_instanciated_component(self, instance_name, component_model)
                else
                    raise NameResolutionError.new(name), "#{name} does not refer to a known task or device (known tasks: #{tasks.keys.sort.join(", ")}; known devices: #{robot.devices.keys.sort.join(", ")})"
                end

                # Check if a service has explicitely been selected, and
                # if it is the case, return it instead of the complete
                # task
                if service_name.empty?
                    return instance
                else
                    service_name = service_name.join(".")
                    candidates = []
                    instance.base_models.each do |m|
                        if srv = m.find_data_service(service_name)
                            candidates << srv
                        end
                    end

                    if candidates.empty?
                        # Look for slave services, if they are not ambiguous
                        instance.base_models.each do |m|
                            m.each_data_service do |srv_name, srv|
                                if srv_name =~ /\.#{service_name}/
                                    candidates << srv
                                end
                            end
                        end
                    end

                    if candidates.size > 1
                        raise ArgumentError, "ambiguity while resolving #{name}: the service name #{service_name} can be resolved into #{candidates.map(&:to_s).join(", ")}"
                    elsif candidates.empty?
                        all_services = instance.models.map do |m|
                            m.each_data_service.map(&:first)
                        end.flatten.uniq.sort
                        if all_services.empty?
                            raise ArgumentError, "no service #{service_name} can be found for #{name}, #{instance} has no known services"
                        else
                            raise ArgumentError, "no service #{service_name} can be found for #{name}, known services are #{all_services.join(", ")} on #{instance}"
                        end
                    end

                    instance.select_service(candidates.first)
                    return instance
                end
            end

            # Helper method that creates an instance of EngineRequirement
            # and registers it
            def self.create_instanciated_component(engine, name, model) # :nodoc:
                if model.respond_to?(:to_str)
                    model = engine.resolve_name(model, name || model)
                end

                if model.kind_of?(DeviceInstance)
                    service = model.service
                    service_model = model.device_model
                    if model.kind_of?(SlaveDeviceInstance)
                        model = model.master_device
                    end

                    requirements = EngineRequirement.new(name, [model.task_model])
                    requirements.with_arguments(model.task_arguments)
                    requirements.with_arguments("#{model.service.name}_name" => model.name)
                    requirements
                elsif model.kind_of?(Module) && (model < Component || model < DataService)
                    EngineRequirement.new(name, [model])
                elsif model.kind_of?(InstanceRequirements)
                    model
                elsif model.kind_of?(InstanceSelection)
                    model
                else
                    raise ArgumentError, "wrong model type #{model.class} for #{model}"
                end
            end

            def resolve_component_definition(model)
                Engine.create_instanciated_component(self, nil, model)
            end

            # Returns a instanciation specification for the given device
            def device(name)
                resolve_name(name, name)
            end

	    def export_defines_to_planner(planner)
	    	defines.each_key do |name|
		    export_define_to_planner(planner, name)
		end
	    end

	    def export_devices_to_planner(planner)
	    	robot.devices.each do |name, device|
		    if device.kind_of?(MasterDeviceInstance)
		        export_device_to_planner(planner, name)
		    end
		end
	    end

	    def export_define_to_planner(planner, name)
	        if !defines.has_key?(name)
		    raise ArgumentError, "no define called #{name} on #{self}"
		end
                if !planner.has_method?(name)
                    planner.method(name) do
                        Orocos::RobyPlugin.require_task name
                    end
                end
	    end

	    def export_device_to_planner(planner, name)
	    	device = robot.devices[name]
		if !device.kind_of?(MasterDeviceInstance)
		    raise ArgumentError, "cannot export a non-master device"
		end

		if !planner.has_method?("#{device.name}_device")
		    planner.method("#{device.name}_device") do
		        spec = Roby.orocos_engine.device(device.name)
		        if arguments[:conf]
		            spec.with_conf(*arguments[:conf])
		        end
		        spec.as_plan
		    end
		end
	    end

            # Define a component instanciation specification, without adding it
            # to the current deployment.
            #
            # The definition can later be used in #add:
            #
            #   define('piv_control', Control).
            #       use('control' => PIVController::Task)
            #
            #   ...
            #   add 'piv_control'
            def define(name, model, arguments = Hash.new)
                selected = user_selection_for(model)
                defines[name] = Engine.create_instanciated_component(self, name, selected)
                export_define_to_planner(::MainPlanner, name)
		defines[name]
            rescue InstanciationError => e
                e.instanciation_chain.push("defining #{name} as #{model}")
                raise
            end

            def user_selection_for(model)
                if model.respond_to?(:to_str) || !model.kind_of?(InstanceRequirements)
                    main_user_selection.selection_for(model) || model
                else
                    model
                end
            end

            # Add a new component requirement to the current deployment
            #
            # +model+ can either be the name of a definition (see Engine#define)
            # or a component model.
            #
            # +arguments+ is a hash that can contain explicit child selection
            # specification (if +model+ is a composition).
            def add(model, arguments = Hash.new)
                arguments = Kernel.validate_options arguments, :as => nil

                selected = user_selection_for(model)
                instance = Engine.create_instanciated_component(self, arguments[:as], selected)

                @modified = true
                instances << instance
                instance
            end

            # Returns true if +obj+ is a definition that is valid given the
            # current system configuration, i.e. if it could be used in #define
            # or #add
            def valid_definition?(spec)
                begin
                    Engine.create_instanciated_component(self, "", spec)
                    true
                rescue ArgumentError
                    false
                end
            end


            # Returns true if +name+ is the name of a definition added with
            # #define
            def has_definition?(name)
                defines.has_key?(name.to_str)
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
                if task.kind_of?(EngineRequirement)
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
                        t.fullfills?([task])
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
                    if !srv.master?
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
                    elsif !(task.plan == plan)
                        raise InternalError, "#{task}, which has been selected for #{key}, is not in #{plan} (is in #{task.plan})"
                    end
                end
            end
            
            def update_main_selection
                # Now prepare the main selection
                main_selection = DependencyInjectionContext.new

                devices = Hash.new
                robot.each_master_device do |name, device_instance|
                    plan.add(task = device_instance.instanciate(self, main_selection))
                    device_instance.task = task
                    register_task(name, task)
                    devices[name] = task
                end
                main_selection.push(devices)

                # First, push the name-to-spec mappings
                main_selection.push(defines)
                # Second, push the automatically-computed selections (if
                # required)
                if use_main_selection?
                    main_selection.push(DependencyInjection.new(main_automatic_selection))
                end
                # Finally, the explicit selections
                main_selection.push(main_user_selection)

                Engine.debug do
                    Engine.debug "Resolved main selection"
                    Engine.log_nest(2) do
                        Engine.log_pp(:debug, main_selection)
                    end
                    break
                end
                @main_selection = main_selection
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

                main_selection = update_main_selection

                instances.each do |instance|
                    instance.task = add_instance(instance, :as => instance.name, :context => main_selection).to_component
                    instance.task.fullfilled_model = instance.fullfilled_model
                end
            end

            # Add a task instance in the plan, during the instanciation process
            #
            # One must NOT use this method outside of the instanciation process
            # !
            def add_instance(instance_def, arguments = Hash.new)
                arguments = Kernel.validate_options arguments, :as => nil, :context => @main_selection, :mission => false
                context = arguments[:context] || DependencyInjectionContext.new

                selected = user_selection_for(instance_def)
                instance = Engine.create_instanciated_component(self, arguments[:as], selected)

                begin
                    context.save
                    plan.add(task = instance.instanciate(self, context))
                ensure
                    context.restore
                end

                if name = arguments[:as]
                    register_task(name, task)
                end

                # This is important here, as #resolve uses
                # static_garbage_collect to clear up the plan
                #
                # However, the permanent flag will be removed at the end
                # of #resolve
                if arguments[:mission]
                    instance.mission = true
                    plan.add_mission(task)
                else
                    plan.add_permanent(task)
                end

                if instance.respond_to?(:selected_services) && (instance.selected_services.size == 1)
                    # The caller is trying to access a particular service. Give
                    # it to him
                    return instance.selected_services.values.first.bind(task)
                else
                    return task
                end
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                Graphviz.new(plan).to_file(kind, 'svg', filename, *additional_args)
            end

            def to_dot_dataflow(remove_compositions = false, excluded_models = ValueSet.new, annotations = ["connection_policy"])
                gen = Graphviz.new(plan)
                gen.dataflow(remove_compositions, excluded_models, annotations)
            end

            def to_dot(options); to_dot_dataflow(options) end

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
                all_tasks = plan.find_local_tasks(Component).
                    to_a

                still_abstract = all_tasks.find_all(&:abstract?)
                if !still_abstract.empty?
                    abstract_tasks = Hash.new
                    still_abstract.each do |task|
                        if task.respond_to?(:proxied_data_services)
                            candidates = task.proxied_data_services.inject(nil) do |set, m|
                                m_candidates = (service_allocation_candidates[m] || ValueSet.new).to_value_set
                                set ||= m_candidates
                                set & m_candidates
                            end
                            abstract_tasks[task] = candidates || ValueSet.new
                        end
                    end

                    raise TaskAllocationFailed.new(abstract_tasks),
                        "could not find implementation for the following abstract tasks: #{still_abstract}"
                end

                plan.find_local_tasks(TaskContext) do |task|
                    seen = Hash.new
                    task.each_concrete_input_connections do |source_task, source_port, sink_port, _|
                        if (port_model = task.model.find_input_port(sink_port)) && port_model.multiplexes?
                            next
                        elsif seen[sink_port]
                            raise SpecError, "#{task}.#{sink_port} is connected multiple times"
                        end
                        seen[sink_port] = true
                    end
                end

                # Check that all devices are properly assigned
                missing_devices = all_tasks.find_all do |t|
                    t.model < Device &&
                        t.model.each_master_device.any? { |srv| !t.arguments["#{srv.name}_name"] }
                end
                if !missing_devices.empty?
                    raise DeviceAllocationFailed.new(self, missing_devices),
                        "could not allocate devices for the following tasks: #{missing_devices}"
                end

                devices = Hash.new
                all_tasks.each do |task|
                    next if !(task.model < Device)
                    task.model.each_master_device do |srv|
                        device_name = task.arguments["#{srv.name}_name"]
                        if old_task = devices[device_name]
                            raise SpecError, "device #{device_name} is assigned to both #{old_task} and #{task}"
                        else
                            devices[device_name] = task
                        end
                    end
                end

                # Call hooks that we might have
                super if defined? super
            end

            def validate_final_network(plan, options = Hash.new)
                # Check that all device instances are proper tasks (not proxies)
                instances.each do |instance|
                    if instance.task.transaction_proxy?
                        raise InternalError, "instance definition #{instance} contains a transaction proxy: #{instance.task}"
                    end
                end
                robot.devices.each do |name, instance|
                    if instance.task && instance.task.transaction_proxy?
                        raise InternalError, "device handler for #{name} contains a transaction proxy: #{instance.task}"
                    end
                end

                if options[:compute_deployments]
                    # Check for the presence of non-deployed tasks
                    not_deployed = plan.find_local_tasks(TaskContext).
                        not_finished.
                        find_all { |t| !t.execution_agent }.
                        delete_if do |p|
                            p.abstract?
                        end

                    if !not_deployed.empty?
                        remaining_merges = @network_merge_solver.complete_merge_graph
                        raise MissingDeployments.new(not_deployed, remaining_merges),
                            "there are tasks for which it exists no deployed equivalent: #{not_deployed.map(&:to_s)}"
                    end
                end

                super if defined? super
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
                add_timepoint 'prepare', 'start'

                Engine.model_postprocessing.each do |block|
                    block.call(model)
                end

                # This caches the mapping from child name to child model to
                # speed up instanciation
                model.each_composition do |composition|
                    composition.prepare
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
                deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.orogen_spec.task_activities.each do |deployed_task|
                            all_concrete_models << Roby.app.orocos_tasks[deployed_task.task_model.name]
                        end
                    end
                end
                robot.devices.each do |name, device|
                    all_concrete_models << device.service
                end

                all_models.merge(all_concrete_models)

                service_allocation_candidates.clear
                result = Hash.new
                add_timepoint 'default_allocations', 'start'

                # For each declared data service, look for models that define
                # them and store the result
                model.each_data_service do |service|
                    candidates = all_concrete_models.
                        find_all { |m| m.fullfills?(service) }.
                        to_value_set

                    # If there are multiple candidates, remove the subclasses
                    candidates.delete_if do |candidate_model|
                        if candidate_model.kind_of?(ProvidedDataService)
                            # Data services are the most precise selection that
                            # we can do ... so no way it is redundant !
                            next
                        end

                        candidates.any? do |other_model|
                            if other_model.kind_of?(Class)
                                other_model != candidate_model && candidate_model <= other_model
                            elsif other_model.kind_of?(ProvidedDataService) && candidate_model == other_model.component_model
                                all_services = candidate_model.find_all_services_from_type(other_model.model)
                                all_services.size == 1
                            end
                        end
                    end

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
                add_timepoint 'default_allocations', 'end'
                @main_automatic_selection = result

                add_timepoint 'prepare', 'done'
            end

            # Updates the tasks in the DataFlowDynamics instance to point to the
            # final tasks (i.e. the ones in the plan) instead of the temporary
            # used during resolution
            def apply_merge_to_dataflow_dynamics
                @dataflow_dynamics.apply_merges(@network_merge_solver)
            end

            def replacement_for(task)
                @network_merge_solver.replacement_for(task)
            end

            # This updates the tasks stored in each instance spec to point to
            # the actual task (i.e. the task that implements that spec in the
            # plan).
            #
            # This is needed as multiple merge steps are done between the
            # initially-instanciated plan and the final plan
            def apply_merge_to_stored_instances
                # Replace the tasks stored in devices and instances by the
                # actual new tasks
                mappings = Hash.new
                instances.each do |instance|
                    new_task = replacement_for(instance.task)
                    if new_task != instance.task
                        NetworkMergeSolver.debug { "updated task of instance #{instance.task} from #{instance.task} to #{new_task}" }
                    end
                    instance.task = new_task
                end
                robot.devices.each do |name, dev|
                    next if !dev.respond_to?(:task=)
                    new_task = replacement_for(dev.task)
                    if new_task != dev.task
                        NetworkMergeSolver.debug { "updated task of device #{name} from #{dev.task} to #{new_task}" }
                    end
                    dev.task = new_task
                end
                @tasks = tasks.map_value do |name, task|
                    new_task = replacement_for(task.to_component)
                    if new_task != task
                        NetworkMergeSolver.debug { "updated named task #{name} from #{task} to #{new_task}" }
                    end
                    if new_task.respond_to?(:child_selection)
                        new_task.child_selection.each_value do |instance_selection|
                            if child_task = instance_selection.selected_task
                                mapped_child_task = replacement_for(child_task.to_component)
                                instance_selection.selected_task = mapped_child_task
                            end
                        end
                    end
                    new_task
                end
                if @deployment_tasks
                    @deployment_tasks = @deployment_tasks.map do |task|
                        new_task = replacement_for(task)
                        if new_task != task
                            NetworkMergeSolver.debug { "updated deployment task #{task} to #{new_task}" }
                        end
                        new_task
                    end
                end
            end

            def add_default_selections(using_spec)
                result = main_selection.merge(using_spec)
                InstanceRequirements.resolve_recursive_selection_mapping(result)
            end

            include Utilrb::Timepoints

            def format_timepoints
                super + @network_merge_solver.format_timepoints
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network
                add_timepoint 'compute_system_network', 'start'
                instanciate
                Engine.instanciation_postprocessing.each do |block|
                    block.call(self, plan)
                end
                add_timepoint 'compute_system_network', 'instanciate'
                @network_merge_solver.merge_identical_tasks
                apply_merge_to_stored_instances

                add_timepoint 'compute_system_network', 'merge'
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, plan)
                    add_timepoint 'compute_system_network', 'postprocessing', block.to_s
                end
                link_to_busses
                add_timepoint 'compute_system_network', 'link_to_busses'
                @network_merge_solver.merge_identical_tasks
                apply_merge_to_stored_instances
                add_timepoint 'compute_system_network', 'merge'

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                plan.find_local_tasks(Component).
                    each do |task|
                        if !task.arguments[:conf]
                            task.arguments[:conf] = ['default']
                        end
                    end
                add_timepoint 'compute_system_network', 'default_conf'

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                plan.static_garbage_collect do |obj|
                    Engine.debug { "  removing #{obj}" }
                    # Remove tasks that we just added and are not
                    # useful anymore
                    plan.remove_object(obj)
                end
                add_timepoint 'compute_system_network', 'static_garbage_collect'

                Engine.system_network_postprocessing.each do |block|
                    block.call(self)
                end
                add_timepoint 'compute_system_network', 'postprocessing'
            end

            # Called after compute_system_network to map the required component
            # network to deployments
            #
            # The deployments are still abstract, i.e. they are not mapped to
            # running tasks yet
            def deploy_system_network(validate_network)
                instanciate_required_deployments
                @network_merge_solver.merge_identical_tasks
                apply_merge_to_stored_instances

                if validate_network
                    validate_deployed_network
                    add_timepoint 'validate_deployed_network'
                end

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                plan.static_garbage_collect do |obj|
                    Engine.debug { "  removing #{obj}" }
                    # Remove tasks that we just added and are not
                    # useful anymore
                    plan.remove_object(obj)
                end
            end

            # Method called to verify that the result of #deploy_system_network
            # is valid
            def validate_deployed_network
                # Check for the presence of non-deployed tasks
                not_deployed = plan.find_local_tasks(TaskContext).
                    find_all { |t| !t.execution_agent }

                if !not_deployed.empty?
                    remaining_merges = @network_merge_solver.complete_merge_graph
                    raise MissingDeployments.new(not_deployed, remaining_merges),
                        "there are tasks for which it exists no deployed equivalent: #{not_deployed.map(&:to_s)}"
                end
            end

            class << self
                # Set of blocks registered with
                # register_model_postprocessing
                attr_reader :model_postprocessing

                # Set of blocks registered with
                # register_instanciation_postprocessing
                attr_reader :instanciation_postprocessing

                # Set of blocks registered with
                # register_instanciated_network_postprocessing
                attr_reader :instanciated_network_postprocessing

                # Set of blocks registered with
                # register_system_network_postprocessing
                attr_reader :system_network_postprocessing

                # Set of blocks registered with
                # register_deployment_postprocessing
                attr_reader :deployment_postprocessing
            end
            @model_postprocessing = Array.new
            @instanciation_postprocessing = Array.new
            @instanciated_network_postprocessing = Array.new
            @system_network_postprocessing = Array.new
            @deployment_postprocessing = Array.new

            # Registers a system-wide post-processing stage for the models.
            # This post-processing block is meant to modify the models according
            # to the activity of some plugins. It can also be used if you want
            # to validate some properties on them.
            #
            # The block will be given the SystemModel object
            def self.register_model_postprocessing(&block)
                model_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the instanciation
            # stage. This post-processing block is meant to add new tasks and
            # new relations in the graph. It runs after the instanciation, but
            # before the first merge pass has been performed. I.e. in this
            # graph, there will be present some duplicate tasks, devices won't
            # be assigned properly, ... Use the
            # instanciated_network_postprocessing hook to be called after this
            # first merge pass.
            #
            # Use it to instanciate/annotate the graph early, i.e. before some
            # system-wide processing is done
            #
            # Postprocessing stages that configures the task(s) automatically
            # should be registered with #register_system_network_postprocessing
            def self.register_instanciation_postprocessing(&block)
                instanciation_postprocessing << block
            end

            # Registers a system-wide post-processing stage for augmenting the
            # system network instanciation. Unlike the instanciation
            # postprocessing stage, a first merge pass has been done on the
            # graph and it is therefore not final but well-formed.
            #
            # Postprocessing stages that configures the task(s) automatically
            # should be registered with #register_system_network_postprocessing
            def self.register_instanciated_network_postprocessing(&block)
                instanciated_network_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the system
            # network (i.e. the complete network before it gets merged with
            # deployed tasks). This post-processing block is meant to
            # automatically configure the tasks and/or dataflow, but not change
            # the task graph
            #
            # Postprocessing stages that change the task graph should be
            # registered with #register_instanciation_postprocessing
            def self.register_system_network_postprocessing(&block)
                system_network_postprocessing << block
            end

            # Registers a system-wide post-processing stage for the deployed
            # network. This post-processing block is meant to automatically
            # configure the tasks and/or dataflow, but not change the task
            # graph. Unlike in #register_system_network_postprocessing, it has
            # access to information that deployment provides (as e.g. port
            # dynamics).
            #
            # Postprocessing stages that change the task graph should be
            # registered with #register_instanciation_postprocessing
            def self.register_deployment_postprocessing(&block)
                deployment_postprocessing << block
            end

            # Hook called by the merge algorithm
            #
            # It updates the +tasks+, robot.devices 'task' attribute and
            # instances hashes
            def merged_tasks(merges)
            end

            # The set of tasks that represent the running deployments
            attr_reader :deployment_tasks

            # The DataFlowDynamics instance that has been used to compute
            # +port_dynamics+. It is only valid at the postprocesing stage of
            # the deployed network
            #
            # It can be used to compute some connection policy by calling
            # DataFlowDynamics#policy_for
            attr_reader :dataflow_dynamics

            # A mapping of type
            #
            #   task_name => port_name => PortDynamics instance
            #
            # that represent the dynamics of the given ports. The PortDynamics
            # instance might be nil, in which case it means some of the ports'
            # dynamics could not be computed
            attr_reader :port_dynamics

            class << self
                # The buffer size used to create connections to the logger in
                # case the dataflow dynamics can't be computed
                #
                # Defaults to 25
                attr_accessor :default_logging_buffer_size
            end
            @default_logging_buffer_size = 25

            # Configures each running deployment's logger, based on the
            # information in +port_dynamics+
            #
            # The "configuration" means that we create the necessary connections
            # between each component's port and the logger
            def configure_logging
                Logger::Logger.include LoggerConfigurationSupport

                deployment_tasks.each do |deployment|
                    next if !deployment.plan

                    logger_task = nil
                    logger_task_name = "#{deployment.deployment_name}_Logger"

                    required_logging_ports = Array.new
                    required_connections   = Array.new
                    deployment.each_executed_task do |t|
                        if t.finishing? || t.finished?
                            next
                        end

                        if !logger_task && t.orocos_name == logger_task_name
                            logger_task = t
                            next
                        elsif t.model.name == "Orocos::RobyPlugin::Logger::Logger"
                            next
                        end

                        connections = Hash.new

                        all_ports = []

                        t.model.each_output_port do |p|
                            all_ports << [p.name, p]
                        end
                        t.instanciated_dynamic_outputs.each do |port_name, port_model|
                            all_ports << [port_name, port_model]
                        end

                        all_ports.each do |port_name, p|
                            next if !deployment.log_port?(p)

                            log_port_name = "#{t.orocos_name}.#{port_name}"
                            connections[[port_name, log_port_name]] = { :fallback_policy => { :type => :buffer, :size => Engine.default_logging_buffer_size } }
                            required_logging_ports << [log_port_name, t, p]
                        end
                        required_connections << [t, connections]
                    end

                    if required_connections.empty?
                        if logger_task
                            # Keep loggers alive even if not needed
                            plan.add_mission(logger_task)
                        end
                        next 
                    end

                    logger_task ||=
                        begin
                            deployment.task(logger_task_name)
                        rescue ArgumentError
                            Engine.warn "deployment #{deployment.deployment_name} has no logger (#{logger_task_name})"
                            next
                        end
                    plan.add_permanent(logger_task)
                    logger_task.default_logger = true
                    # Make sure that the tasks are started after the logger was
                    # started
                    deployment.each_executed_task do |t|
                        if t.pending?
                            t.should_start_after logger_task.start_event
                        end
                    end

                    if logger_task.setup?
                        # The logger task is already configured. Add the ports
                        # manually
                        #
                        # Otherwise, Logger#configure will take care of it for
                        # us
                        required_logging_ports.each do |port_name, logged_task, logged_port|
                            logger_task.createLoggingPort(port_name, logged_task, logged_port)
                        end
                    else
                        logger_task.needs_reconfiguration!
                    end
                    required_connections.each do |task, connections|
                        connections = connections.map_value do |(port_name, log_port_name), policy|
                            out_port = task.find_output_port_model(port_name)

                            if !logger_task.find_input_port_model(log_port_name)
                                logger_task.instanciate_dynamic_input(log_port_name, out_port.type)
                            end
                            dataflow_dynamics.policy_for(task, port_name, log_port_name, logger_task, policy)
                        end

                        task.connect_ports(logger_task, connections)
                    end
                end

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                plan.find_local_tasks(Orocos::RobyPlugin::Logger::Logger).
                    each do |task|
                        if !task.arguments[:conf]
                            task.arguments[:conf] = ['default']
                        end
                    end

                # Mark as permanent any currently running logger
                plan.find_tasks(Orocos::RobyPlugin::Logger::Logger).
                    not_finished.
                    each do |t|
                        plan.add_permanent(t)
                    end
            end

            # The set of options last given to #instanciate. It is used by
            # plugins to configure their behaviours
            attr_accessor :options

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
            # on_error::
            #   by default, #resolve will generate a dot file containing the
            #   current plan state if an error occurs. This corresponds to a
            #   :save value for this option. It can also be set to :commit, in
            #   which case the current state of the transaction is committed to
            #   the plan, allowing to display it anyway (for debugging of models
            #   for instance). Set it to false to do no special action (i.e.
            #   drop the currently generated plan)
            def resolve(options = Hash.new)
                @timepoints = []
	    	return if disabled?

                # Set some objects to nil to make sure that noone is using them
                # while they are not valid
                @dataflow_dynamics =
                    @port_dynamics =
                    @deployment_tasks = nil

                if options == true
                    options = { :compute_policies => true }
                end
                options = Kernel.validate_options options,
                    :compute_policies    => true,
                    :compute_deployments => true,
                    :garbage_collect => true,
                    :export_plan_on_error => nil,
                    :save_plans => false,
                    :validate_network => true,
                    :forced_removes => false,
                    :on_error => :save # internal flag

                if !options[:export_plan_on_error].nil?
                    options[:on_error] =
                        if options[:export_plan_on_error] then :save
                        else false
                        end
                end

                # It makes no sense to compute the policies if we are not
                # computing the deployments, as policy computation needs
                # deployment information
                if !options[:compute_deployments]
                    options[:compute_policies] = false
                    options[:validate_network] = false
                end

                self.options = options

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
                trsc = @plan = Roby::Transaction.new(plan)
                @network_merge_solver = NetworkMergeSolver.new(trsc, &method(:merged_tasks))

                begin
                    @plan = trsc

                    instances.delete_if do |instance|
                        if (pending_removes.has_key?(instance.task) || pending_removes.has_key?(instance))
                            true
                        else
                            false
                        end
                    end

                    # We first generate a non-deployed network that fits all
                    # requirements. This can fail if some service cannot be
                    # allocated to tasks, and if some drivers cannot be
                    # allocated to devices.
                    compute_system_network

                    add_timepoint

                    if options[:garbage_collect] && options[:validate_network]
                        validate_generated_network(trsc, options)
                        add_timepoint 'validate_generated_network'
                    end

                    # Now, deploy the network by matching the available
                    # deployments to the one in the generated network. Note that
                    # these deployments are *not* yet the running tasks.
                    #
                    # The mapping from this deployed network to the running
                    # tasks is done in #finalize_deployed_tasks
                    if options[:compute_deployments]
                        deploy_system_network(options[:validate_network])
                        add_timepoint 'deploy_system_network'
                    end

                    # Now that we have a deployed network, we can compute the
                    # connection policies and the port dynamics, and call the
                    # registered postprocessing blocks
                    if options[:compute_policies]
                        @dataflow_dynamics = DataFlowDynamics.new(trsc)
                        @port_dynamics = dataflow_dynamics.compute_connection_policies
                        add_timepoint 'compute_connection_policies'
                        Engine.deployment_postprocessing.each do |block|
                            block.call(self, plan)
                            add_timepoint 'deployment_postprocessing', block.to_s
                        end
                    end

                    # Finally, we map the deployed network to the currently
                    # running tasks
                    if options[:compute_deployments]
                        add_timepoint 'compute_deployment', 'start'
                        used_tasks = trsc.find_local_tasks(Component).
                            to_value_set
                        used_deployments = trsc.find_local_tasks(Deployment).
                            to_value_set

                        add_timepoint 'compute_deployment', 'finalized_deployed_tasks'
                        @deployment_tasks = finalize_deployed_tasks(used_tasks, used_deployments, options[:garbage_collect])
                        add_timepoint 'compute_deployment', 'merge'
                        @network_merge_solver.merge_identical_tasks
                        add_timepoint 'compute_deployment', 'done'
                    end

                    if options[:garbage_collect]
                        Engine.debug "final garbage collection pass"
                        trsc.static_garbage_collect do |obj|
                            if obj.transaction_proxy?
                                Engine.debug { "  removing dependency relations from #{obj}" }
                                # Clear up the dependency relations for the
                                # obsolete tasks that are in the plan
                                obj.remove_relations(Roby::TaskStructure::Dependency)
                            else
                                Engine.debug { "  removing #{obj}" }
                                # Remove tasks that we just added and are not
                                # useful anymore
                                trsc.remove_object(obj)
                            end
                        end
                    end

                    # Remove the permanent and mission flags from all the tasks.
                    # We then re-add them only for the ones that are marked as
                    # mission in the engine requirements
                    trsc.find_local_tasks.permanent.each do |t|
                        trsc.unmark_permanent(t)
                    end
                    trsc.find_tasks(Deployment).each do |t|
                        trsc.add_permanent(t)
                    end

                    if options[:compute_deployments]
                        if defined?(Orocos::RobyPlugin::Logger::Logger)
                            configure_logging
                        end
                    end

                    fullfilled_models = Hash.new

                    plan.each_task do |task|
                        if task.transaction_proxy?
                            @network_merge_solver.register_replacement(task, task.__getobj__)
                        end
                    end

                    # Update tasks, devices and instances
                    apply_merge_to_stored_instances
                    # Update the dataflow dynamics information to point to the
                    # final tasks
                    if @dataflow_dynamics
                        apply_merge_to_dataflow_dynamics
                    end

                    # Replace the tasks stored in devices and instances by the
                    # actual new tasks
                    instances.each do |instance|
                        old_task = state_backup.instance_tasks[instance]
                        new_task = instance.task
                        if instance.mission?
                            trsc.add_mission(trsc[new_task])
                        end

                        if old_task && old_task.plan && old_task != new_task
                            trsc.replace(trsc[old_task], trsc[new_task])
                        end

                        m = (fullfilled_models[new_task] || [Roby::Task, Array.new, Hash.new])
                        m = Roby::TaskStructure::Dependency.merge_fullfilled_model(m, instance.models, instance.arguments)
                        fullfilled_models[new_task] = m
                    end

                    fullfilled_models.each do |task, m|
                        if !m[1].kind_of?(Array)
                            raise "Array found in fullfilled model"
                        end
                        task.fullfilled_model = m
                    end

                    robot.devices.keys.each do |name|
                        next if !robot.devices[name].respond_to?(:task=)

                        device_task = robot.devices[name].task
                        if !device_task.plan
                            robot.devices[name].task = nil
                        end
                    end

                    # Finally, we should now only have deployed tasks. Verify it
                    # and compute the connection policies
                    if options[:garbage_collect] && options[:validate_network]
                        validate_final_network(trsc, options)
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
                    if options[:on_error] == :save
                        Roby.log_pp(e, Roby, :fatal)
                        Engine.fatal "Engine#resolve failed"
                        begin
                            output_path = autosave_plan_to_dot
                            Engine.fatal "the generated plan has been saved into #{output_path}"
                            Engine.fatal "use dot -Tsvg #{output_path} > #{output_path}.svg to convert to SVG"
                        rescue Exception => e
                            Engine.fatal "failed to save the generated plan: #{e}"
                        end
                    end

                    if options[:on_error] == :commit
                        trsc.commit_transaction
                    else
                        trsc.discard_transaction
                    end
                    raise
                end

            rescue Exception => e
                if options[:on_error] == :commit
                    raise
                end

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
                if @network_merge_solver
                    @network_merge_solver.task_replacement_graph.clear
                    @network_merge_solver = nil
                end
                @dataflow_dynamics = nil
            end

            def autosave_plan_to_dot(dir = Roby.app.log_dir, options = Hash.new)
                Engine.autosave_plan_to_dot(plan, dir, options)
            end

            @@dot_index = 0
            def self.autosave_plan_to_dot(plan, dir = Roby.app.log_dir, options = Hash.new)
                options, dot_options = Kernel.filter_options options,
                    :prefix => nil, :suffix => nil
                output_path = File.join(dir, "orocos-engine-plan-#{options[:prefix]}%04i#{options[:suffix]}.dot" % [@@dot_index += 1])
                File.open(output_path, 'w') do |io|
                    io.write Graphviz.new(plan).dataflow(dot_options)
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
                task.start_event.ensure com_bus_task.start_event

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
                    next if !(source_model < Device)
                    device_spec = robot.devices[task.arguments["#{source_name}_name"]]
                    next if !device_spec || !device_spec.com_bus_names.include?(bus_name)
                    
                    in_ports =
                        if in_candidates.size > 1
                            in_candidates.
                                find_all { |p| p.name =~ /#{source_name}/i }
                        else
                            in_candidates
                        end

                    out_ports =
                        if out_candidates.size > 1
                            out_candidates.
                                find_all { |p| p.name =~ /#{source_name}/i }
                        else
                            out_candidates
                        end

                    if in_ports.size > 1
                        raise Ambiguous, "there are multiple options to connect #{bus_name} to #{source_name} in #{task}: #{in_ports.map(&:name)}"
                    elsif out_ports.size > 1
                        raise Ambiguous, "there are multiple options to connect #{source_name} in #{task} to #{bus_name}: #{out_ports.map(&:name)}"
                    end

                    handled[source_name] = [!out_ports.empty?, !in_ports.empty?]
                    if !in_ports.empty?
                        port = in_ports.first
                        used_ports << port.name
                        com_out_port = com_bus.model.output_name_for(device_spec.name)
                        com_bus_task.port_to_device[com_out_port] << device_spec.name
                        in_connections[ [com_out_port, port.name] ] = Hash.new
                    end
                    if !out_ports.empty?
                        port = out_ports.first
                        used_ports << port.name
                        com_in_port = com_bus_in || com_bus.model.input_name_for(device_spec.name)
                        com_bus_task.port_to_device[com_in_port] << device_spec.name
                        out_connections[ [port.name, com_in_port] ] = Hash.new
                    end
                end

                # if there are some unconnected devices, search for
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
                        task.each_master_device do |service, device|
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
                        task.each_master_device do |service, device|
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
                candidates = plan.find_local_tasks(Orocos::RobyPlugin::Device).
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

                deployment_tasks = Hash.new
                deployed_tasks = Hash.new

                deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        task = model.new(:on => machine_name)
                        plan.add(task)
                        task.robot = robot
                        deployment_tasks[model] = task

                        new_activities = Set.new
                        task.orogen_spec.task_activities.each do |deployed_task|
                            if ignored_deployed_task?(deployed_task)
                                Engine.debug { "  ignoring #{model.name}.#{deployed_task.name} as it is of type #{deployed_task.task_model.name}" }
                            else
                                new_activities << deployed_task.name
                            end
                        end

                        new_activities.each do |act_name|
                            new_task = task.task(act_name)
                            deployed_task = plan[new_task]
                            Engine.debug do
                                "  #{deployed_task.orogen_name} on #{task.deployment_name}[machine=#{task.machine}] is represented by #{deployed_task}"
                            end
                            deployed_tasks[act_name] = deployed_task
                        end
                    end
                end
                Engine.debug do
                    Engine.debug "Done instanciating deployments"
                    Engine.debug "----------------------------------------------------"
                    Engine.debug ""
                    break
                end

                return deployment_tasks, deployed_tasks
            end

            def finalize_deployed_tasks(used_tasks, used_deployments, garbage_collect)
                all_tasks = plan.find_tasks(Component).to_value_set
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
                            plan.remove_object(t)
                            true
                        end
                    end
                end

                (all_tasks - used_tasks).each do |t|
                    Engine.debug { "clearing the relations of #{t}" }
                    t.remove_relations(Orocos::RobyPlugin::Flows::DataFlow)
                end

                if garbage_collect
                    used_deployments.each do |task|
                        plan.unmark_permanent(task)
                    end

                    plan.static_garbage_collect do |obj|
                        used_deployments.delete(obj)
                        if obj.transaction_proxy?
                            # Clear up the dependency relations for the
                            # obsolete tasks that are in the plan
                            obj.remove_relations(Roby::TaskStructure::Dependency)
                        else
                            # Remove tasks that we just added and are not
                            # useful anymore
                            plan.remove_object(obj)
                        end
                    end
                end

                # We finally have a deployed system, using the deployments
                # specified by the user
                #
                # However, it is not yet *the* deployed sytem, as we have to
                # check how to play well with currently running tasks.
                #
                # That's what this method does
                deployments = used_deployments
                existing_deployments = plan.find_tasks(Orocos::RobyPlugin::Deployment).to_value_set - deployments

                Engine.debug do
                    Engine.debug "mapping deployments in the network to the existing ones"
                    Engine.debug "network deployments:"
                    deployments.each { |dep| Engine.debug "  #{dep}" }
                    Engine.debug "existing deployments:"
                    existing_deployments.each { |dep| Engine.debug "  #{dep}" }
                    break
                end

                result = ValueSet.new
                deployments.each do |deployment_task|
                    Engine.debug { "looking to reuse a deployment for #{deployment_task.deployment_name} (#{deployment_task})" }
                    # Check for the corresponding task in the plan
                    existing_deployment_tasks = (plan.find_local_tasks(deployment_task.model).not_finished.to_value_set & existing_deployments).
                        find_all { |t| t.deployment_name == deployment_task.deployment_name }

                    if existing_deployment_tasks.empty?
                        Engine.debug { "  #{deployment_task.deployment_name} has not yet been deployed" }
                        result << deployment_task
                        next
                    elsif existing_deployment_tasks.size != 1
                        raise InternalError, "more than one task for #{existing_deployment_task} present in the plan"
                    end
                    existing_deployment_task = existing_deployment_tasks.find { true }

                    existing_tasks = Hash.new
                    existing_deployment_task.each_executed_task do |t|
                        if t.running?
                            existing_tasks[t.orogen_name] = t
                        elsif t.pending?
                            existing_tasks[t.orogen_name] ||= t
                        end
                    end

		    Engine.debug existing_tasks

                    deployed_tasks = deployment_task.each_executed_task.to_value_set
                    deployed_tasks.each do |task|
                        existing_task = existing_tasks[task.orogen_name]
                        if !existing_task
                            Engine.debug { "  task #{task.orogen_name} has not yet been deployed" }
                        elsif !existing_task.reusable?
                            Engine.debug { "  task #{task.orogen_name} has been deployed, but the deployment is not reusable" }
                        elsif !existing_task.can_merge?(task)
                            Engine.debug { "  task #{task.orogen_name} has been deployed, but I can't merge with the existing deployment" }
                        end

                        # puts "#{existing_task} #{existing_task.meaningful_arguments} #{existing_task.arguments} #{existing_task.fullfilled_model}"
                        # puts "#{task} #{task.meaningful_arguments} #{task.arguments} #{task.fullfilled_model}"
                        # puts existing_task.can_merge?(task)
                        if !existing_task || existing_task.finishing? || !existing_task.reusable? || !existing_task.can_merge?(task)
                            new_task = plan[existing_deployment_task.task(task.orogen_name, task.model)]
                            Engine.debug { "  creating #{new_task} for #{task} (#{task.orogen_name})" }
                            if existing_task
                                new_task.start_event.should_emit_after(existing_task.stop_event)

                                # The trick with allow_automatic_setup is to
                                # force the sequencing of stop / configure /
                                # start
                                #
                                # So we wait for the existing task to either be
                                # finished or finalized, and only then do we
                                # allow the system to configure +new_task+
                                new_task.allow_automatic_setup = false
                                existing_task.stop_event.when_unreachable do |reason, _|
                                    new_task.allow_automatic_setup = true
                                end
                            end
                            existing_task = new_task
                        end
                        existing_task.merge(task)
                        @network_merge_solver.register_replacement(task, plan.may_unwrap(existing_task))
                        Engine.debug { "  using #{existing_task} for #{task} (#{task.orogen_name})" }
                        plan.remove_object(task)
                        if existing_task.conf != task.conf
                            existing_task.needs_reconfiguration!
                        end
                    end
                    plan.remove_object(deployment_task)
                    result << existing_deployment_task
                end
                result
            end

            # Helper class used to load files that contain both system model and
            # engine requirements
            #
            # See Engine#load_composite_file
            class CompositeLoader < BasicObject
                def initialize(engine)
                    @engine = engine
                end

                def method_missing(m, *args, &block)
                    if !@engine.respond_to?(m) && @engine.model.respond_to?(m)
                        @engine.model.send(m, *args, &block)
                    else
                        @engine.send(m, *args, &block)
                    end
                end
            end

            # Load a file that contains both system model and engine
            # requirements
            def load_composite_file(file)
                loader = CompositeLoader.new(self)
                if Kernel.load_dsl_file(file, loader, RobyPlugin.constant_search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
            end

            # Load the given DSL file into this Engine instance
            def load(file)
                if Kernel.load_dsl_file(file, self, RobyPlugin.constant_search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
            end

            def load_system_model(file)
                Roby.app.load_system_model(file)
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
        def self.update_task_states(plan) # :nodoc:
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
                    not_finished
                plan.instance_variable_set :@orocos_update_query, query
            end

            query.reset
            for t in query
                # The task's deployment is not started yet
                next if !t.orogen_task

                if !t.execution_agent
                    raise NotImplementedError, "#{t} is not yet finished but has no execution agent. #{t}'s history is\n  #{t.history.map(&:to_s).join("\n  ")}"
                elsif !t.execution_agent.ready?
                    raise InternalError, "orogen_task != nil on #{t}, but #{t.execution_agent} is not ready yet"
                end

                # Some CORBA implementations (namely, omniORB) may behave weird
                # if the remote process terminates in the middle of a remote
                # call.
                #
                # Ignore tasks whose process is terminating to reduce the
                # likelihood of that happening
		if t.execution_agent.ready_to_die?
		    next
		end

                if t.pending? && !t.setup? 
                    if t.ready_for_setup? && Roby.app.orocos_auto_configure?
                        begin
                            t.setup 
                            t.is_setup!
                        rescue Exception => e
                            t.event(:start).emit_failed(e)
                        end
                        next
                    end
                end

                handled_this_cycle = Array.new
                next if !t.running?

                begin
                    state = nil
                    state_count = 0
                    while (!state || t.orogen_task.runtime_state?(state)) && t.update_orogen_state
                        state_count += 1
                        state = t.orogen_state

                        # Returns nil if we have a communication problem. In this
                        # case, #update_orogen_state will have emitted the right
                        # events for us anyway
                        if state && handled_this_cycle.last != state
                            t.handle_state_changes
                            handled_this_cycle << state
                        end
                    end


                    if state_count >= TaskContext::STATE_READER_BUFFER_SIZE
                        Engine.warn "got #{state_count} state updates for #{t}, we might have lost some state updates in the process"
                    end

                rescue Orocos::CORBA::ComError => e
                    t.emit :aborted, e
                end
            end
        end

        def self.apply_requirement_modifications(plan)
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
        end
    end
end


