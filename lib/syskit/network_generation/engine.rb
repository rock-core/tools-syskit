module Syskit
    module NetworkGeneration
        module PlanExtension
            attr_accessor :syskit_engine
        end

        # The main deployment algorithm
        #
        # Engine instances are the objects that actually get deployment
        # requirements and produce a deployment, possibly dynamically.
        #
        # The main entry point for the algorithm is Engine#resolve
        class Engine
            extend Logger::Hierarchy
            include Logger::Hierarchy

            include Utilrb::Timepoints

            def format_timepoints
                super + merge_solver.format_timepoints
            end

            # The actual plan we are modifying
            attr_reader :real_plan
            # The plan we are modifying. It is usually a transaction on top of
            # #plan
            #
            # This is valid only during resolution
            #
            # It is alised to {#plan} for backward compatibility reasons
            attr_reader :work_plan
            # The robot on which the software is running
            attr_reader :robot
            # A mapping from requirement tasks in the real plan to the tasks
            # that have been instantiated in the working plan
            #
            # This is only valid during resolution
            attr_reader :required_instances
            # A list of data service or component models for which a deployment
            # exists. It includes compositions that have all their children
            # deployed as well
            #
            # It is only valid during resolution
            attr_reader :deployed_models
            # A mapping from task context models to deployment models that
            # contain such a task.
            # @return [Hash{Model<TaskContext>=>Model<Deployment>}]
            attr_reader :task_context_deployment_candidates
            # The merge solver instance used during resolution
            #
            # @return [MergeSolver]
            attr_reader :merge_solver

            class << self
                # If false (the default), {Engine#resolve} will clear the data
                # structures built during resoltuion such as
                # {#required_instances} and {#merge_solver}. This improves
                # performance by reducing the required garbage collection times
                # quite a lot. 
                #
                # Set to true only for debugging reasons
                attr_predicate :keep_internal_data_structures?, true
            end
            @keep_internal_data_structures = false

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
	    def enable_updates; @disabled = false end

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

            # The set of options last given to #instanciate. It is used by
            # plugins to configure their behaviours
            attr_accessor :options

            def initialize(plan, robot = Syskit.conf.robot)
                @real_plan = plan
                @work_plan = plan
                @robot     = robot
                real_plan.extend PlanExtension
                real_plan.syskit_engine = self

                @merge_solver = NetworkGeneration::MergeSolver.new(real_plan)
                @use_automatic_selection = true

                @main_automatic_selection = DependencyInjection.new

                @service_allocation_candidates = Hash.new
            end

            # The set of selections computed based on what is actually available
            # on this system
            #
            # It can be disabled by setting #use_automatic_selection to false
            attr_reader :main_automatic_selection

            # A mapping from data service models to concrete models
            # (compositions and/or task models) that implement it
            #
            # This is used for error message generation / debugging purposes
            attr_reader :service_allocation_candidates

            # Returns the set of deployments that are available for this network
            # generation
            def available_deployments
                Syskit.conf.deployments
            end

            # Computes the set of task context models that are available in
            # deployments
            def compute_deployed_models
                deployed_models = ValueSet.new

                new_models = ValueSet.new
                available_deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.each_orogen_deployed_task_context_model do |deployed_task|
                            new_models << TaskContext.model_for(deployed_task.task_model)
                        end
                    end
                end

                while !new_models.empty?
                    deployed_models.merge(new_models)

                    # First, add everything the new models fullfill
                    fullfilled_models = ValueSet.new
                    new_models.each do |m|
                        m.each_fullfilled_model do |fullfilled_m|
                            next if !(fullfilled_m <= Syskit::Component) && !(fullfilled_m.kind_of?(Models::DataServiceModel))
                            if !deployed_models.include?(fullfilled_m)
                                fullfilled_models << fullfilled_m
                            end
                        end
                    end
                    deployed_models.merge(fullfilled_models)

                    # No new fullfilled models, finish
                    break if fullfilled_models.empty?

                    # Look into which compositions we are able to instantiate
                    # with the newly added fullfilled models
                    new_models.clear
                    Composition.each_submodel do |composition_m|
                        next if deployed_models.include?(composition_m)
                        available = composition_m.each_child.all? do |child_name, child_m|
                            child_m.each_fullfilled_model.all? do |fullfilled_m|
                                deployed_models.include?(fullfilled_m)
                            end
                        end
                        if available
                            new_models << composition_m
                        end
                    end
                end

                deployed_models.delete(Syskit::TaskContext)
                deployed_models.delete(Syskit::DataService)
                deployed_models.delete(Syskit::Composition)
                deployed_models.delete(Syskit::Component)

                deployed_models
            end

            def update_deployed_models
                @deployed_models = compute_deployed_models
                @deployed_component_models = deployed_models.find_all { |m| m <= Component }
                @task_context_deployment_candidates = compute_task_context_deployment_candidates

                # Fill in the service_allocation_candidates mapping
                service_allocation_candidates.clear
                @deployed_component_models.each do |component_m|
                    component_m.each_fullfilled_model do |fullfilled_m|
                        if fullfilled_m <= DataService
                            service_allocation_candidates[fullfilled_m] ||= ValueSet.new
                            service_allocation_candidates[fullfilled_m] << component_m
                        end
                    end
                end
            end

            # Must be called everytime the system model changes. It updates the
            # values that are cached to speed up the instanciation process
            def prepare(options = Hash.new)
                add_timepoint 'prepare', 'start'

                options = validate_resolve_options(options)
                self.options = options

                Engine.model_postprocessing.each do |block|
                    block.call
                end

                update_deployed_models

                # And compute the default selections
                @main_automatic_selection = DependencyInjection.new
                main_automatic_selection.add_defaults(@deployed_component_models)

                @work_plan = Roby::Transaction.new(real_plan)
                @merge_solver = NetworkGeneration::MergeSolver.new(work_plan)
                @required_instances = Hash.new

                add_timepoint 'prepare', 'done'
            end
            
            # Resets the state of the solver to be ready for another call to
            # #resolve
            #
            # It should be called as soon as #prepare has been called
            def finalize
                if work_plan && (work_plan != real_plan)
                    if !work_plan.finalized?
                        work_plan.discard_transaction
                    end
                    @work_plan = real_plan
                end
                if !Engine.keep_internal_data_structures?
                    merge_solver.task_replacement_graph.clear
                    @merge_solver = NetworkGeneration::MergeSolver.new(work_plan)
                    @required_instances.clear if @required_instances
                end
            end

            # If true, the engine will compute for each service the set of
            # concrete task models that provides it. If that set is one element,
            # it will automatically add it to the set of default selection.
            #
            # If false, this mechanism is ignored
            #
            # It is true by default
            attr_predicate :use_automatic_selection?, true

            # Computes the dependency injection object that contains the devices
            # and the main automatic selection (if use_automatic_selection? is
            # true)
            #
            # @return [DependencyInjectionContext]
            def compute_main_dependency_injection
                main_selection = DependencyInjectionContext.new

                # Push the devices as a name-to-task mapping
                devices = Hash.new
                robot.each_master_device do |name, device_instance|
                    task = device_instance.instanciate(work_plan, main_selection)
                    devices[name] = task
                    task.model.each_data_service do |_, srv|
                        devices["#{name}.#{srv.full_name}"] = task
                    end
                end
                main_selection.push(devices)

                # Push the automatically-computed selections if it is required
                if use_automatic_selection?
                    main_selection.push(main_automatic_selection)
                end

                debug do
                    debug "Resolved main selection"
                    log_nest(2) do
                        log_pp(:debug, main_selection)
                    end
                    break
                end
                main_selection
            end

            # Given a task and a DI context, autoselect devices when possible
            def allocate_devices(task, context)
                Engine.debug do
                    Engine.debug "allocating devices on #{task} using"
                    Engine.log_nest(2) do
                        Engine.log_pp :debug, context
                    end
                    break
                end
                    
                task.model.each_master_driver_service do |srv|
                    next if task.find_device_attached_to(srv)
                    _, model, _ = context.selection_for(nil, srv.model.to_instance_requirements)
                    puts "found #{model} for #{srv.model} in #{task}"
                    if dev = model.arguments["#{srv.name}_dev"]
                        Engine.debug do
                            Engine.debug "  selected #{dev} for #{srv.name}"
                        end
                        task.arguments["#{srv.name}_dev"] = dev
                    end
                end
            end

            # Create on {#work_plan} the task instances that are currently
            # required in {#real_plan}
            #
            # It does not try to merge the result, {#work_plan} is probably full
            # of redundancies after this call
            #
            # @return [void]
            def instanciate(req_tasks = nil)
                main_selection = compute_main_dependency_injection

                if !req_tasks
                    req_tasks = real_plan.find_local_tasks(InstanceRequirementsTask).
                        find_all do |req_task|
                            !req_task.failed? && !req_task.pending? &&
                                req_task.planned_task && !req_task.planned_task.finished?
                        end
                    not_needed = real_plan.unneeded_tasks
                    req_tasks.delete_if do |t|
                        not_needed.include?(t)
                    end
                end

                req_tasks.each do |req_task|
                    req = req_task.requirements
                    task = req.instanciate(work_plan, main_selection).
                        to_task
                    # We add all these tasks as permanent tasks, to use
                    # #static_garbage_collect to cleanup #work_plan. The
                    # actual mission / permanent marking is fixed at the end
                    # of resolution by calling #fix_toplevel_tasks
                    work_plan.add_permanent(task)
                    task.fullfilled_model = req.fullfilled_model
                    required_instances[req_task] = task

                    task.generated_subgraph(Roby::TaskStructure::Dependency).each do |task|
                        if task.respond_to?(:each_master_driver_service)
                            allocate_devices(task, req.dependency_injection_context)
                        end
                    end
                end
            end

            # Creates communication busses and links the tasks to them
            def link_to_busses
                # Get all the tasks that need at least one communication bus
                candidates = work_plan.find_local_tasks(Syskit::Device).
                    inject(Hash.new) do |h, t|
                        required_busses = t.each_master_device.inject(Array.new) do |list, dev|
                            list + dev.com_busses
                        end.to_set
                        if !required_busses.empty?
                            h[t] = required_busses
                        end
                        h
                    end

                bus_tasks = Hash.new
                candidates.each do |task, needed_busses|
                    needed_busses.each do |bus_device|
                        com_bus_task = bus_tasks[bus_device] ||
                            bus_device.instanciate(work_plan)
                        bus_tasks[bus_device] ||= com_bus_task

                        com_bus_task = com_bus_task.component
                        com_bus_task.attach(task)
                        task.depends_on com_bus_task
                        task.should_start_after com_bus_task.start_event
                    end
                end
                nil
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network(req_tasks = nil)
                add_timepoint 'compute_system_network', 'start'
                instanciate(req_tasks)
                Engine.instanciation_postprocessing.each do |block|
                    block.call(self, work_plan)
                end
                add_timepoint 'compute_system_network', 'instanciate'
                merge_solver.merge_identical_tasks

                add_timepoint 'compute_system_network', 'merge'
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, work_plan)
                    add_timepoint 'compute_system_network', 'postprocessing', block.to_s
                end
                link_to_busses
                add_timepoint 'compute_system_network', 'link_to_busses'
                merge_solver.merge_identical_tasks
                add_timepoint 'compute_system_network', 'merge'

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                work_plan.find_local_tasks(Component).
                    each do |task|
                        if !task.arguments[:conf]
                            task.arguments[:conf] = ['default']
                        end
                    end
                add_timepoint 'compute_system_network', 'default_conf'

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                if options[:garbage_collect]
                    work_plan.static_garbage_collect do |obj|
                        debug { "  removing #{obj}" }
                        # Remove tasks that we just added and are not
                        # useful anymore
                        work_plan.remove_object(obj)
                    end
                    add_timepoint 'compute_system_network', 'static_garbage_collect'
                end

                Engine.system_network_postprocessing.each do |block|
                    block.call(self)
                end
                add_timepoint 'compute_system_network', 'postprocessing'

                if options[:validate_network]
                    validate_generated_network(work_plan, options)
                    add_timepoint 'validate_generated_network'
                end
            end
            
            # Validates the network generated by {#compute_system_network}
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
                        else
                            abstract_tasks[task] = plan.find_local_tasks(task.class).to_value_set
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
                        t.model.each_master_driver_service.any? { |srv| !t.find_device_attached_to(srv) }
                end
                if !missing_devices.empty?
                    raise DeviceAllocationFailed.new(self, missing_devices),
                        "could not allocate devices for the following tasks: #{missing_devices}"
                end

                devices = Hash.new
                all_tasks.each do |task|
                    next if !(task.model < Device)
                    task.each_master_device do |dev|
                        device_name = dev.full_name
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

            # Computes a mapping from task models to the set of registered
            # deployments that apply on these task models
            #
            # @return [{Model<TaskContext>=>[(String,Model<Deployment>,String)]}]
            #   mapping from task context models to a set of
            #   (machine_name,deployment_model,task_name) tuples representing
            #   the known ways this task context model could be deployed
            def compute_task_context_deployment_candidates
                deployed_models = Hash.new
                available_deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.each_orogen_deployed_task_context_model do |deployed_task|
                            task_model = TaskContext.model_for(deployed_task.task_model)
                            deployed_models[task_model] ||= ValueSet.new
                            deployed_models[task_model] << [machine_name, model, deployed_task.name]
                        end
                    end
                end
                deployed_models
            end

            # Try to resolve a set of deployment candidates for a given task
            #
            # @param [Array<(String,Model<Deployment>,String)>] candidates set
            #   of deployment candidates as
            #   (machine_name,deployment_model,task_name) tuples
            # @param [Syskit::TaskContext] task the task context for which
            #   candidates are possible deployments
            # @return [(String,Model<Deployment>,String),nil] the resolved
            #   deployment, if finding a single best candidate was possible, or
            #   nil otherwise.
            def resolve_deployment_ambiguity(candidates, task)
                if task.orocos_name
                    resolved = candidates.find { |_, _, task_name| task_name == task.orocos_name }
                    if !resolved
                        debug "cannot find requested orocos name #{task.orocos_name}"
                    end
                    return resolved
                else
                    # Look to disambiguate using deployment hints
                    resolved = candidates.find_all do |_, deployment_model, task_name|
                        task.deployment_hints.any? do |rx|
                            rx === task_name
                        end
                    end
                    if resolved.size != 1
                        debug do
                            debug "ambiguous deployment for #{task} (#{task.model.name})"
                            candidates.each do |machine, deployment_model, task_name|
                                debug "  #{task_name} of #{deployment_model.short_name} on #{machine}"
                            end
                            break
                        end
                        return
                    end
                    return resolved.first
                end
            end

            # Called after compute_system_network to map the required component
            # network to deployments
            #
            # We are still purely within {#work_plan}, the mapping to
            # {#real_plan} is done by calling {#finalize_deployed_tasks}
            def deploy_system_network
                debug "deploying the system network"

                deployed_models = task_context_deployment_candidates
                used_deployments = Set.new

                missing_deployments = []
                deployment_tasks = Hash.new
                all_tasks = work_plan.find_local_tasks(TaskContext).to_a
                all_tasks.each do |task|
                    next if task.execution_agent # This is already deployed

                    # task.model would be wrong here as task.model could be the
                    # singleton class (if there are dynamic services)
                    candidates = deployed_models[task.class]
                    if !candidates || candidates.empty?
                        debug { "no deployments found for #{task} (#{task.model.short_name})" }
                        missing_deployments << task
                        next
                    elsif candidates.size > 1
                        if !(selected = resolve_deployment_ambiguity(candidates, task))
                            debug { "deployment of #{task} (#{task.model.short_name}) is ambiguous" }
                            missing_deployments << task
                            next
                        end
                    else
                        selected = candidates.first
                    end

                    machine, configured_deployment, task_name = *selected
                    if used_deployments.include?(selected)
                        # Already used somewhere else, don't reallocate
                        debug { "#{task} resolves to #{configured_deployment.short_name}.#{task_name} for its deployment, but it is already used" }
                        missing_deployments << task
                        next
                    end
                    
                    used_deployments << selected
                    deployment_task = configured_deployment.new(:on => machine)
                    work_plan.add(deployment_task)
                    deployed_task = deployment_task.task(task_name)
                    debug { "deploying #{task} with #{task_name} of #{configured_deployment.short_name} (#{deployed_task})" }
                    merge_solver.merge(task, deployed_task)
                end

                if options[:validate_network]
                    validate_deployed_network
                    add_timepoint 'validate_deployed_network'
                end

                missing_deployments
            end

            # Sanity checks to verify that the result of #deploy_system_network
            # is valid
            #
            # @raise [MissingDeployments] if some tasks could not be deployed
            def validate_deployed_network
                # Check for the presence of non-deployed tasks
                not_deployed = work_plan.find_local_tasks(TaskContext).
                    find_all { |t| !t.execution_agent }

                if !not_deployed.empty?
                    tasks_with_candidates = Hash.new
                    not_deployed.each do |task|
                        tasks_with_candidates[task] = task_context_deployment_candidates[task.class] || []
                    end
                    raise MissingDeployments.new(tasks_with_candidates),
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

                # Set of blocks registered with
                # register_final_network_postprocessing
                attr_reader :final_network_postprocessing
            end
            @model_postprocessing = Array.new
            @instanciation_postprocessing = Array.new
            @instanciated_network_postprocessing = Array.new
            @system_network_postprocessing = Array.new
            @deployment_postprocessing = Array.new
            @final_network_postprocessing = Array.new

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

            # Registers a system-wide post-processing stage for the final
            # network. This is the last stage before the last validation
            def self.register_final_network_postprocessing(&block)
                final_network_postprocessing << block
            end

            # Updates the tasks stored in {#required_instances} and in
            # {#dataflow_dynamics} with the tasks that will replace them in
            # {#real_plan} once the {#work_plan} transaction is committed.
            #
            # It also updates the merge graph in {#merge_solver} so that
            # it points to tasks in {#real_plan}
            def apply_merge_to_stored_instances
                work_plan.each_task do |task|
                    if task.transaction_proxy?
                        merge_solver.register_replacement(task, task.__getobj__)
                    end
                end

                @required_instances = required_instances.map_value do |_, task|
                    merge_solver.replacement_for(task)
                end
                if @dataflow_dynamics
                    @dataflow_dynamics.apply_merges(merge_solver)
                end
            end

            # Replaces the toplevel tasks (i.e. tasks planned by the
            # InstanceRequirementsTask tasks) by their computed implementation.
            #
            # Also updates the permanent and mission flags for these tasks.
            def fix_toplevel_tasks
                work_plan.each_task do |t|
                    work_plan.unmark_permanent(t)
                    work_plan.unmark_mission(t)
                end
                required_instances.each do |req_task, actual_task|
                    is_permanent = real_plan.permanent?(req_task.planned_task)
                    is_mission   = real_plan.mission?(req_task.planned_task)

                    placeholder_task = work_plan[req_task.planned_task]
                    req_task         = work_plan[req_task]
                    actual_task      = work_plan.may_wrap(actual_task)

                    if is_permanent
                        work_plan.add_permanent(actual_task)
                    end
                    if is_mission
                        work_plan.add_mission(actual_task)
                    end

                    if placeholder_task != actual_task
                        work_plan.replace(placeholder_task, actual_task)
                        # Need to switch the planning relation as well, it is
                        # not done by #replace
                        placeholder_task.remove_planning_task req_task
                        actual_task.add_planning_task req_task
                    end

                end
            end

            def validate_resolve_options(options)
                options = Kernel.validate_options options,
                    :requirement_tasks   => nil,
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
                # If we don't garbage collect, the plan will always contain
                # garbage and the validation will fail. Disable.
                if !options[:garbage_collect]
                    options[:validate_network] = false
                end
                options
            end

            # Given the network with deployed tasks, this method looks at how we
            # could adapt the running network to the new one
            def finalize_deployed_tasks
                debug "finalizing deployed tasks"

                used_deployments = work_plan.find_local_tasks(Deployment).to_value_set
                used_tasks       = work_plan.find_local_tasks(Component).to_value_set

                all_tasks = work_plan.find_tasks(Component).to_value_set
                all_tasks.delete_if do |t|
                    if !t.reusable?
                        debug { "  clearing the relations of the finished task #{t}" }
                        t.remove_relations(Syskit::Flows::DataFlow)
                        t.remove_relations(Roby::TaskStructure::Dependency)
                        true
                    elsif t.transaction_proxy?
                        if t.abstract?
                            work_plan.remove_object(t)
                            true
                        end
                    end
                end

                (all_tasks - used_tasks).each do |t|
                    debug { "  #{t} is not used in the new network, clearing its dataflow relations" }
                    t.remove_relations(Syskit::Flows::DataFlow)
                end

                existing_deployments = work_plan.find_tasks(Syskit::Deployment).
                    not_finishing.not_finished.to_value_set
                existing_deployments = existing_deployments - used_deployments

                debug do
                    debug "  Mapping deployments in the network to the existing ones"
                    debug "    Network deployments:"
                    used_deployments.each { |dep| debug "      #{dep}" }
                    debug "    Existing deployments:"
                    existing_deployments.each { |dep| debug "      #{dep}" }
                    break
                end

                result = ValueSet.new
                used_deployments.each do |deployment_task|
                    # We need to search for #class and not #model here as
                    # otherwise we would never find anything for tasks with
                    # dynamic services
                    existing_candidates = work_plan.find_local_tasks(deployment_task.class).
                        not_finishing.not_finished.to_value_set
                    debug do
                        debug "  looking to reuse a deployment for #{deployment_task.process_name} (#{deployment_task})"
                        debug "  #{existing_candidates.size} candidates:"
                        existing_candidates.each do |candidate_task|
                            debug "    #{candidate_task}"
                        end
                        break
                    end

                    # Check for the corresponding task in the plan
                    existing_deployment_tasks = (existing_candidates & existing_deployments).
                        find_all do |t|
                            t.process_name == deployment_task.process_name
                        end

                    if existing_deployment_tasks.empty?
                        debug { "  deployment #{deployment_task.process_name} is not yet represented in the plan" }
                        # Nothing to do, we leave the plan as it is
                        result << deployment_task
                    elsif existing_deployment_tasks.size != 1
                        raise InternalError, "more than one task for #{existing_deployment_task} present in the plan"
                    else
                        adapt_existing_deployment(deployment_task, existing_deployment_tasks.first)
                        result << existing_deployment_tasks.first
                    end
                end

                # This is required to merge the already existing compositions
                # with the ones in the plan
                merge_solver.merge_identical_tasks
                result
            end

            # Given a required deployment task in {#work_plan} and a proxy
            # representing an existing deployment task in {#real_plan}, modify
            # the plan to reuse the existing deployment
            def adapt_existing_deployment(deployment_task, existing_deployment_task)
                existing_tasks = Hash.new
                existing_deployment_task.each_executed_task do |t|
                    next if t.finished? || t.finishing?
                    if t.running?
                        existing_tasks[t.orocos_name] = t
                    elsif t.pending?
                        existing_tasks[t.orocos_name] ||= t
                    end
                end

                deployed_tasks = deployment_task.each_executed_task.to_a
                deployed_tasks.each do |task|
                    existing_task = existing_tasks[task.orocos_name]
                    if !existing_task || !existing_task.can_merge?(task)
                        debug do
                            if !existing_task
                                "  task #{task.orocos_name} has not yet been deployed"
                            elsif !existing_task.can_merge?(task)
                                "  task #{task.orocos_name} has been deployed, but I can't merge with the existing deployment"
                            end
                        end

                        new_task = existing_deployment_task.task(task.orocos_name, task.model)
                        debug { "  creating #{new_task} for #{task} (#{task.orocos_name})" }
                        if existing_task
                            debug { "  #{new_task} needs to wait for #{existing_task} to finish before reconfiguring" }
                            new_task.should_configure_after(existing_task.stop_event)
                        end
                        existing_task = new_task
                    end

                    merge_solver.merge(task, existing_task)
                    debug { "  using #{existing_task} for #{task} (#{task.orocos_name})" }
                end
                work_plan.remove_object(deployment_task)
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

                prepare(options)
                # We use simply "options" below, which resolves to the local
                # variable. Update it.
                options = self.options

                # We first generate a non-deployed network that fits all
                # requirements.
                compute_system_network(options[:requirement_tasks])

                # Now, deploy the network by matching the available
                # deployments to the one in the generated network. Note that
                # these deployments are *not* yet the running tasks.
                #
                # The mapping from this deployed network to the running
                # tasks is done in #finalize_deployed_tasks
                if options[:compute_deployments]
                    deploy_system_network
                    add_timepoint 'deploy_system_network'

                    # Now that we have a deployed network, we can compute the
                    # connection policies and the port dynamics
                    if options[:compute_policies]
                        @dataflow_dynamics = DataFlowDynamics.new(work_plan)
                        @port_dynamics = dataflow_dynamics.compute_connection_policies
                        add_timepoint 'compute_connection_policies'
                    end

                    # Finally, we map the deployed network to the currently
                    # running tasks
                    add_timepoint 'compute_deployment', 'start'
                    @deployment_tasks = finalize_deployed_tasks
                    add_timepoint 'compute_deployment', 'done'

                    Engine.deployment_postprocessing.each do |block|
                        block.call(self, work_plan)
                        add_timepoint 'deployment_postprocessing', block.to_s
                    end
                end

                apply_merge_to_stored_instances
                fix_toplevel_tasks

                Engine.final_network_postprocessing.each do |block|
                    block.call(self, work_plan)
                    add_timepoint 'final_network_postprocessing', block.to_s
                end

                # Finally, we should now only have deployed tasks. Verify it
                # and compute the connection policies
                if options[:garbage_collect] && options[:validate_network]
                    validate_final_network(work_plan, options)
                end

                if options[:save_plans]
                    output_path = Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                    info "saved generated plan into #{output_path}"
                end
                work_plan.commit_transaction

            rescue Exception => e
                if work_plan != real_plan # we started processing, look at what the user wants to do with the partial transaction
                    if options[:on_error] == :save
                        log_pp(:fatal, e)
                        fatal "Engine#resolve failed"
                        begin
                            output_path = Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                            fatal "the generated plan has been saved into #{output_path}"
                            fatal "use dot -Tsvg #{output_path} > #{output_path}.svg to convert to SVG"
                        rescue Exception => e
                            fatal "failed to save the generated plan: #{e}"
                        end
                    end

                    if options[:on_error] == :commit
                        work_plan.commit_transaction
                    else
                        work_plan.discard_transaction
                    end
                end
                raise

            ensure
                finalize
            end

            # Validates the state of the network at the end of #resolve
            def validate_final_network(plan, options = Hash.new)
                # Check that all device instances are proper tasks (not proxies)
                required_instances.each do |req_task, task|
                    if task.transaction_proxy?
                        raise InternalError, "instance definition #{instance} contains a transaction proxy: #{instance.task}"
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
                        remaining_merges = merge_solver.complete_merge_graph
                        raise MissingDeployments.new(not_deployed, remaining_merges),
                            "there are tasks for which it exists no deployed equivalent: #{not_deployed.map(&:to_s)}"
                    end
                end

                super if defined? super
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

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                Graphviz.new(work_plan).to_file(kind, 'svg', filename, *additional_args)
            end

            def to_dot_dataflow(remove_compositions = false, excluded_models = ValueSet.new, annotations = ["connection_policy"])
                gen = Graphviz.new(work_plan)
                gen.dataflow(remove_compositions, excluded_models, annotations)
            end

            def to_dot(options); to_dot_dataflow(options) end

            def pretty_print(pp) # :nodoc:
                pp.text "-- Tasks"
                pp.nest(2) do
                    pp.breakable
                    work_plan.each_task do |task|
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
        end
    end
end


