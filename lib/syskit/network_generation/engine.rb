module Syskit
    module NetworkGeneration
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
            # The robot on which the software is running
            attr_reader :robot
            # A name => Task mapping of tasks we built so far
            attr_reader :tasks
            # The set of deployment names we should use
            attr_reader :deployments

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

            # :method: modified?
            #
            # True if the requirements changed since the last call to #resolve
            attr_predicate :modified

            # Force marking the specification as modified, triggering a system
            # update
            def modified!
                @modified = true
            end

            def initialize(plan)
                @plan      = plan
                plan.extend PlanExtension
                plan.orocos_engine = self

                @network_merge_solver = NetworkGeneration::MergeSolver.new(plan, &method(:merged_tasks))
                @use_main_selection = true

                @tasks     = Hash.new
                @deployments = Hash.new { |h, k| h[k] = Set.new }
                @main_automatic_selection = DependencyInjection.new
                @modified  = false
            end

            # The set of selections computed based on what is actually available
            # on this system
            #
            # It can be disabled by setting #use_main_selection to false
            attr_reader :main_automatic_selection

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

                debug do
                    debug "Resolved main selection"
                    log_nest(2) do
                        log_pp(:debug, main_selection)
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

                main_selection = update_main_selection

                instances.each do |instance|
                    instance.task = add_instance(instance, :as => instance.name, :context => main_selection).to_component
                    instance.task.fullfilled_model = instance.fullfilled_model
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

                # We now compute default selections for data service models. It
                # computes if there is only one non-abstract task model that
                # provides a given data service, and -- if it is the case --
                # will add it to the 'use' sets
                all_concrete_models = ValueSet.new
                all_models = Composition.submodels.dup
                all_concrete_models = all_models.
                    find_all { |m| !m.abstract? }.
                    to_value_set

                deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        model.orogen_model.task_activities.each do |deployed_task|
                            task_model = TaskContext.model_for(deployed_task.task_model)
                            while task_model
                                all_concrete_models << task_model
                                task_model = task_model.supermodel
                            end
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
                DataService.each_submodel do |service|
                    candidates = all_concrete_models.
                        find_all { |m| m.fullfills?(service) }.
                        to_value_set

                    # If there are multiple candidates, remove the subclasses
                    candidates.delete_if do |candidate_model|
                        if candidate_model.kind_of?(Models::BoundDataService)
                            # Data services are the most precise selection that
                            # we can do ... so no way it is redundant !
                            next
                        end

                        candidates.any? do |other_model|
                            if other_model.kind_of?(Class)
                                other_model != candidate_model && candidate_model <= other_model
                            elsif other_model.kind_of?(Models::BoundDataService) && candidate_model == other_model.component_model
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

                add_timepoint 'compute_system_network', 'merge'
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, plan)
                    add_timepoint 'compute_system_network', 'postprocessing', block.to_s
                end
                link_to_busses
                add_timepoint 'compute_system_network', 'link_to_busses'
                @network_merge_solver.merge_identical_tasks
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
                    debug { "  removing #{obj}" }
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

                if validate_network
                    validate_deployed_network
                    add_timepoint 'validate_deployed_network'
                end

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                plan.static_garbage_collect do |obj|
                    debug { "  removing #{obj}" }
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

                engine_plan = @plan
                trsc = @plan = Roby::Transaction.new(plan)
                @network_merge_solver = NetworkGeneration::MergeSolver.new(trsc, &method(:merged_tasks))

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

                    # Remove the permanent and mission flags from all the tasks.
                    # We then re-add them only for the ones that are marked as
                    # mission in the engine requirements
                    fix_toplevel_mission_permanent

                    if options[:garbage_collect]
                        debug "final garbage collection pass"
                        trsc.static_garbage_collect do |obj|
                            if obj.transaction_proxy?
                                if obj.finished?
                                    debug { "  removing dependency relations from #{obj}" }
                                    # Clear up the dependency relations for the
                                    # obsolete tasks that are in the plan
                                    obj.remove_relations(Roby::TaskStructure::Dependency)
                                end
                            else
                                debug { "  removing #{obj}" }
                                # Remove tasks that we just added and are not
                                # useful anymore
                                trsc.remove_object(obj)
                            end
                        end
                    end

                    plan.each_task do |task|
                        if task.transaction_proxy?
                            @network_merge_solver.register_replacement(task, task.__getobj__)
                        end
                    end

                    # Update the dataflow dynamics information to point to the
                    # final tasks
                    if @dataflow_dynamics
                        apply_merge_to_dataflow_dynamics
                    end

                    # Replace the tasks stored in devices and instances by the
                    # actual new tasks
                    fix_toplevel_fullfilled_models

                    Engine.final_network_postprocessing.each do |block|
                        block.call(self, plan)
                        add_timepoint 'final_network_postprocessing', block.to_s
                    end

                    # Finally, we should now only have deployed tasks. Verify it
                    # and compute the connection policies
                    if options[:garbage_collect] && options[:validate_network]
                        validate_final_network(trsc, options)
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
                raise

            ensure
                @plan = engine_plan
                if @network_merge_solver
                    @network_merge_solver.task_replacement_graph.clear
                    @network_merge_solver = NetworkGeneration::MergeSolver.new(plan, &method(:merged_tasks))
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

                task.model.each_root_data_service do |source_service|
                    source_name  = source_service.name
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
                candidates = plan.find_local_tasks(Syskit::Device).
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
                TaskContext.model_for(deployed_task.task_model).name == "Logger::Logger"
            end

            # Instanciates all deployments that have been specified by the user.
            # Reuses deployments in the current plan manager's plan if possible
            def instanciate_required_deployments
                debug do
                    debug ""
                    debug "----------------------------------------------------"
                    debug "Instanciating deployments"
                    break
                end

                deployment_tasks = Hash.new
                deployed_tasks = Hash.new

                deployments.each do |machine_name, deployment_models|
                    deployment_models.each do |model|
                        debug { "  #{machine_name}: #{model}" }
                        task = model.new(:on => machine_name)
                        plan.add(task)
                        deployment_tasks[model] = task

                        new_activities = Set.new
                        task.each_orogen_deployed_task_context_model do |deployed_task|
                            if ignored_deployed_task?(deployed_task)
                                debug { "  ignoring #{model.name}.#{deployed_task.name} as it is of type #{deployed_task.task_model.name}" }
                            else
                                new_activities << deployed_task.name
                            end
                        end

                        new_activities.each do |act_name|
                            new_task = task.task(act_name)
                            deployed_task = plan[new_task]
                            debug do
                                "  #{deployed_task.orocos_name} using #{task.deployment_name}[machine=#{task.machine}] is represented by #{deployed_task}"
                            end
                            deployed_tasks[act_name] = deployed_task
                        end
                    end
                end
                debug do
                    debug "Done instanciating deployments"
                    debug "----------------------------------------------------"
                    debug ""
                    break
                end

                return deployment_tasks, deployed_tasks
            end

            def finalize_deployed_tasks(used_tasks, used_deployments, garbage_collect)
                all_tasks = plan.find_tasks(Component).to_value_set
                all_tasks.delete_if do |t|
                    if t.finishing? || t.finished?
                        debug { "clearing the relations of the finished task #{t}" }
                        t.remove_relations(Syskit::Flows::DataFlow)
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
                    debug { "clearing the dataflow relations of #{t}" }
                    t.remove_relations(Syskit::Flows::DataFlow)
                end

                if garbage_collect
                    used_deployments.each do |task|
                        plan.unmark_permanent(task)
                    end

                    plan.static_garbage_collect do |obj|
                        used_deployments.delete(obj)
                        if obj.transaction_proxy? 
                            if obj.finished?
                                # Clear up the dependency relations for the
                                # obsolete tasks that are in the plan
                                obj.remove_relations(Roby::TaskStructure::Dependency)
                            end
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
                existing_deployments = plan.find_tasks(Syskit::Deployment).to_value_set - deployments

                debug do
                    debug "mapping deployments in the network to the existing ones"
                    debug "network deployments:"
                    deployments.each { |dep| debug "  #{dep}" }
                    debug "existing deployments:"
                    existing_deployments.each { |dep| debug "  #{dep}" }
                    break
                end

                result = ValueSet.new
                deployments.each do |deployment_task|
                    existing_candidates = plan.find_local_tasks(deployment_task.model).not_finished.to_value_set
                    debug do
                        debug "looking to reuse a deployment for #{deployment_task.deployment_name} (#{deployment_task})"
                        debug "#{existing_candidates.size} candidates:"
                        existing_candidates.each do |candidate_task|
                            debug "  #{candidate_task}"
                        end
                        break
                    end

                    # Check for the corresponding task in the plan
                    existing_deployment_tasks = (existing_candidates & existing_deployments).
                        find_all do |t|
                            t.deployment_name == deployment_task.deployment_name
                        end

                    if existing_deployment_tasks.empty?
                        debug { "  deployment #{deployment_task.deployment_name} is not yet represented in the plan" }
                        result << deployment_task
                        next
                    elsif existing_deployment_tasks.size != 1
                        raise InternalError, "more than one task for #{existing_deployment_task} present in the plan"
                    end
                    existing_deployment_task = existing_deployment_tasks.find { true }

                    existing_tasks = Hash.new
                    existing_deployment_task.each_executed_task do |t|
                        if t.running?
                            existing_tasks[t.orocos_name] = t
                        elsif t.pending?
                            existing_tasks[t.orocos_name] ||= t
                        end
                    end

		    debug existing_tasks

                    deployed_tasks = deployment_task.each_executed_task.to_value_set
                    deployed_tasks.each do |task|
                        existing_task = existing_tasks[task.orocos_name]
                        if !existing_task
                            debug { "  task #{task.orocos_name} has not yet been deployed" }
                        elsif !existing_task.reusable?
                            debug { "  task #{task.orocos_name} has been deployed, but the deployment is not reusable" }
                        elsif !existing_task.can_merge?(task)
                            debug { "  task #{task.orocos_name} has been deployed, but I can't merge with the existing deployment" }
                        end

                        # puts "#{existing_task} #{existing_task.meaningful_arguments} #{existing_task.arguments} #{existing_task.fullfilled_model}"
                        # puts "#{task} #{task.meaningful_arguments} #{task.arguments} #{task.fullfilled_model}"
                        # puts existing_task.can_merge?(task)
                        if !existing_task || existing_task.finishing? || !existing_task.reusable? || !existing_task.can_merge?(task)
                            new_task = plan[existing_deployment_task.task(task.orocos_name, task.model)]
                            debug { "  creating #{new_task} for #{task} (#{task.orocos_name})" }
                            if existing_task
                                debug { "  #{new_task} needs to wait for #{existing_task} to finish before reconfiguring" }
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
                        debug { "  using #{existing_task} for #{task} (#{task.orocos_name})" }
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
        end
    end
end


