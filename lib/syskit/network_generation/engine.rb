# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # The main deployment algorithm
        #
        # Engine instances are the objects that actually get deployment
        # requirements and produce a deployment, possibly dynamically.
        #
        # The main entry point for the algorithm is Engine#resolve
        class Engine
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            class << self
                # Globally controls what happens when resolution fails
                #
                # The default is to throw away everything. Set to :save to save
                # the state of the transaction at the point of error into a dot
                # file. Set to :commit to apply it on the plan anyways
                attr_accessor :on_error
            end
            @on_error = nil

            # The underlying plan
            attr_reader :real_plan
            # The plan we are modifying. It is usually a transaction on top of
            # #plan
            attr_reader :work_plan
            # A mapping from task context models to deployment models that
            # contain such a task.
            # @return [Hash{Model<TaskContext>=>Model<Deployment>}]
            attr_reader :task_context_deployment_candidates
            # The merge solver instance used during resolution
            #
            # @return [MergeSolver]
            attr_reader :merge_solver

            # The set of deployment tasks that are in-use after adaptation of
            # the running plan
            attr_reader :deployment_tasks

            # The set of tasks that are in-use after adaptation of the running plan
            attr_reader :deployed_tasks

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

            attr_reader :event_logger

            def initialize(plan, work_plan: Roby::Transaction.new(plan),
                event_logger: plan.event_logger)
                @real_plan = plan
                @work_plan = work_plan
                @merge_solver = NetworkGeneration::MergeSolver.new(work_plan)
                @event_logger = event_logger
                @required_instances = {}
            end

            # Returns the set of deployments that are available for this network
            # generation
            def available_deployments
                Syskit.conf.deployments
            end

            # Transform the system network into a deployed network
            #
            # This does not access {#real_plan}
            def compute_deployed_network(
                default_deployment_group: Syskit.conf.deployment_group,
                compute_policies: true,
                validate_deployed_network: true
            )
                log_timepoint_group "deploy_system_network" do
                    deployer = SystemNetworkDeployer.new(
                        work_plan,
                        event_logger: event_logger,
                        merge_solver: merge_solver,
                        default_deployment_group: default_deployment_group
                    )

                    deployer.deploy(validate: validate_deployed_network)
                end

                # Now that we have a deployed network, we can compute the
                # connection policies and the port dynamics
                if compute_policies
                    @dataflow_dynamics = DataFlowDynamics.new(work_plan)
                    @port_dynamics = dataflow_dynamics.compute_connection_policies
                    log_timepoint "compute_connection_policies"
                end
            end

            # Apply the deployed network created with
            # {#compute_deployed_network} to the existing plan
            #
            # It accesses {#real_plan}
            def apply_deployed_network_to_plan
                # Finally, we map the deployed network to the currently
                # running tasks
                @deployment_tasks, @deployed_tasks =
                    log_timepoint_group "finalize_deployed_tasks" do
                        finalize_deployed_tasks
                    end

                if @dataflow_dynamics
                    @dataflow_dynamics.apply_merges(merge_solver)
                    log_timepoint "apply_merged_to_dataflow_dynamics"
                end
                Engine.deployment_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "postprocessing:#{block}"
                end
            end

            class << self
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
            @instanciation_postprocessing = []
            @instanciated_network_postprocessing = []
            @system_network_postprocessing = []
            @deployment_postprocessing = []
            @final_network_postprocessing = []

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

            # Updates the tasks stored in {#dataflow_dynamics} with the tasks
            # that will replace them in {#real_plan} once the {#work_plan}
            # transaction is committed.
            #
            # It also updates the merge graph in {#merge_solver} so that
            # it points to tasks in {#real_plan}
            def apply_merge_to_stored_instances
                work_plan.each_task do |task|
                    if task.transaction_proxy?
                        merge_solver.register_replacement(task, task.__getobj__)
                    end
                end

                @dataflow_dynamics&.apply_merges(merge_solver)
            end

            # Replaces the toplevel tasks (i.e. tasks planned by the
            # InstanceRequirementsTask tasks) by their computed implementation.
            #
            # Also updates the permanent and mission flags for these tasks.
            def fix_toplevel_tasks(required_instances)
                if required_instances.empty?
                    return
                end

                replacement_filter = Roby::Plan::ReplacementFilter.new
                                                                  .exclude_relation(Syskit::Flows::DataFlow)
                                                                  .exclude_tasks(work_plan.find_local_tasks(Syskit::Component))

                required_instances.each do |req_task, actual_task|
                    placeholder_task = work_plan.wrap_task(req_task.planned_task)
                    req_task         = work_plan.wrap_task(req_task)
                    actual_task      = work_plan.wrap_task(actual_task)

                    if placeholder_task != actual_task
                        work_plan.replace(placeholder_task, actual_task,
                                          filter: replacement_filter)
                        # Need to switch the planning relation as well, it is
                        # not done by #replace
                        placeholder_task.remove_planning_task req_task
                        actual_task.add_planning_task req_task
                    end
                end
            end

            # Given the network with deployed tasks, this method looks at how we
            # could adapt the running network to the new one
            def finalize_deployed_tasks
                debug "finalizing deployed tasks"

                used_deployments = work_plan.find_local_tasks(Deployment).to_set
                used_tasks       = work_plan.find_local_tasks(Component).to_set
                log_timepoint "used_tasks"

                all_tasks = work_plan.find_tasks(Component).to_set
                log_timepoint "import_all_tasks_from_plan"
                all_tasks.delete_if do |t|
                    if !t.reusable?
                        debug { "  clearing the relations of the finished task #{t}" }
                        t.remove_relations(Syskit::Flows::DataFlow)
                        t.remove_relations(Roby::TaskStructure::Dependency)
                        true
                    elsif t.transaction_proxy? && t.abstract?
                        work_plan.remove_task(t)
                        true
                    end
                end
                log_timepoint "all_tasks_cleanup"

                # Remove connections that are not forwarding connections (e.g.
                # composition exports)
                dataflow_graph = work_plan.task_relation_graph_for(Syskit::Flows::DataFlow)
                all_tasks.each do |t|
                    next if used_tasks.include?(t)

                    dataflow_graph.in_neighbours(t).dup.each do |source_t|
                        connections = dataflow_graph.edge_info(source_t, t).dup
                        connections.delete_if do |(source_port, sink_port), policy|
                            !(source_t.find_output_port(source_port) && t.find_output_port(sink_port)) &&
                                !(source_t.find_input_port(source_port) && t.find_input_port(sink_port))
                        end
                        if !connections.empty?
                            dataflow_graph.set_edge_info(source_t, t, connections)
                        else
                            dataflow_graph.remove_edge(source_t, t)
                        end
                    end
                end
                log_timepoint "dataflow_graph_cleanup"

                deployments = work_plan.find_tasks(Syskit::Deployment).not_finished
                finishing_deployments = {}
                existing_deployments = Set.new
                deployments.each do |task|
                    if task.finishing?
                        finishing_deployments[task.process_name] = task
                    elsif !used_deployments.include?(task)
                        existing_deployments << task
                    end
                end
                log_timepoint "existing_and_finished_deployments"

                debug do
                    debug "  Mapping deployments in the network to the existing ones"
                    debug "    Network deployments:"
                    used_deployments.each { |dep| debug "      #{dep}" }
                    debug "    Existing deployments:"
                    existing_deployments.each { |dep| debug "      #{dep}" }
                    break
                end

                newly_deployed_tasks = Set.new
                reused_deployed_tasks = Set.new
                selected_deployment_tasks = Set.new
                used_deployments.each do |deployment_task|
                    existing_candidates = work_plan
                                          .find_local_tasks(deployment_task.model)
                                          .not_finishing.not_finished.to_set

                    # Check for the corresponding task in the plan
                    existing_deployment_tasks = (existing_candidates & existing_deployments)
                                                .find_all do |t|
                        t.process_name == deployment_task.process_name
                    end

                    debug do
                        debug "  looking to reuse a deployment for #{deployment_task.process_name} (#{deployment_task})"
                        debug "  #{existing_deployment_tasks.size} candidates:"
                        existing_deployment_tasks.each do |candidate_task|
                            debug "    #{candidate_task}"
                        end
                        break
                    end

                    if existing_deployment_tasks.empty?
                        debug { "  deployment #{deployment_task.process_name} is not yet represented in the plan" }
                        # Nothing to do, we leave the plan as it is
                        newly_deployed_tasks.merge(deployment_task.each_executed_task)
                        selected_deployment = deployment_task
                    elsif existing_deployment_tasks.size != 1
                        raise InternalError, "more than one task for #{deployment_task.process_name} present in the plan: #{existing_deployment_tasks}"
                    else
                        selected_deployment = existing_deployment_tasks.first
                        new_merged_tasks = adapt_existing_deployment(
                            deployment_task,
                            selected_deployment
                        )
                        reused_deployed_tasks.merge(new_merged_tasks)
                    end
                    if finishing = finishing_deployments[selected_deployment.process_name]
                        selected_deployment.should_start_after finishing.stop_event
                    end
                    selected_deployment_tasks << selected_deployment
                end
                log_timepoint "select_deployments"

                reused_deployed_tasks = reconfigure_tasks_on_static_port_modification(
                    reused_deployed_tasks
                )
                log_timepoint "reconfigure_tasks_on_static_port_modification"

                debug do
                    debug "#{reused_deployed_tasks.size} tasks reused during deployment"
                    reused_deployed_tasks.each do |t|
                        debug "  #{t}"
                    end
                    break
                end

                # This is required to merge the already existing compositions
                # with the ones in the plan
                merge_solver.merge_identical_tasks
                log_timepoint "merge"

                [selected_deployment_tasks, reused_deployed_tasks | newly_deployed_tasks]
            end

            # After the deployment phase, we check whether some static ports are
            # modified and cause their task to be reconfigured.
            #
            # Note that tasks that are already reconfigured because of
            # {#adapt_existing_deployment} will be fine as the task is not
            # configured yet
            def reconfigure_tasks_on_static_port_modification(deployed_tasks)
                final_deployed_tasks = deployed_tasks.dup

                # We filter against 'deployed_tasks' to always select the tasks
                # that have been selected in this deployment. It does mean that
                # the task is always the 'current' one, that is we would pick
                # the new deployment task and ignore the one that is being
                # replaced
                already_setup_tasks = work_plan.find_tasks(Syskit::TaskContext).not_finished.not_finishing
                                               .find_all { |t| deployed_tasks.include?(t) && (t.setting_up? || t.setup?) }

                already_setup_tasks.each do |t|
                    if t.transaction_modifies_static_ports?
                        debug { "#{t} was selected as deployment, but it would require modifications on static ports, spawning a new deployment" }

                        new_task = t.execution_agent.task(t.orocos_name, t.concrete_model)
                        merge_solver.apply_merge_group(t => new_task)
                        new_task.should_configure_after t.stop_event
                        final_deployed_tasks.delete(t)
                        final_deployed_tasks << new_task
                    end
                end
                final_deployed_tasks
            end

            # Find the "last" deployed task in a set of related deployed tasks
            # in the plan
            #
            # Ordering is encoded in the should_configure_after relation
            def find_current_deployed_task(deployed_tasks)
                configuration_precedence_graph =
                    work_plan.event_relation_graph_for(Roby::EventStructure::SyskitConfigurationPrecedence)
                tasks = deployed_tasks.find_all do |t|
                    t.reusable? && configuration_precedence_graph.leaf?(t.stop_event)
                end
                if tasks.size > 1
                    raise InternalError, "could not find the current task in #{deployed_tasks.map(&:to_s).sort.join(', ')}"
                end

                tasks.first
            end

            # Given a required deployment task in {#work_plan} and a proxy
            # representing an existing deployment task in {#real_plan}, modify
            # the plan to reuse the existing deployment
            #
            # @return [Array<Syskit::TaskContext>] the set of TaskContext
            #   instances that have been used to replace the task contexts
            #   generated during network generation. They are all deployed by
            #   existing_deployment_task, and some of them might be transaction
            #   proxies.
            def adapt_existing_deployment(deployment_task, existing_deployment_task)
                orocos_name_to_existing = {}
                existing_deployment_task.each_executed_task do |t|
                    next if t.finished?

                    (orocos_name_to_existing[t.orocos_name] ||= []) << t
                end

                applied_merges = Set.new
                deployed_tasks = deployment_task.each_executed_task.to_a
                deployed_tasks.each do |task|
                    existing_tasks = orocos_name_to_existing[task.orocos_name] ||
                        []
                    unless existing_tasks.empty?
                        existing_task = find_current_deployed_task(existing_tasks)
                    end

                    if !existing_task || !task.can_be_deployed_by?(existing_task)
                        debug do
                            if !existing_task
                                "  task #{task.orocos_name} has not yet been deployed"
                            else
                                "  task #{task.orocos_name} has been deployed, but I can't merge with the existing deployment (#{existing_task})"
                            end
                        end

                        new_task = existing_deployment_task.task(task.orocos_name, task.concrete_model)
                        debug { "  creating #{new_task} for #{task} (#{task.orocos_name})" }
                        existing_tasks.each do |previous_task|
                            debug { "  #{new_task} needs to wait for #{existing_task} to finish before reconfiguring" }
                            parent_task_contexts = previous_task.each_parent_task
                                                                .find_all { |t| t.kind_of?(Syskit::TaskContext) }
                            parent_task_contexts.each do |t|
                                t.remove_child(previous_task)
                            end
                            new_task.should_configure_after(previous_task.stop_event)
                        end
                        existing_task = new_task
                    end

                    merge_solver.apply_merge_group(task => existing_task)
                    applied_merges << existing_task
                    debug { "  using #{existing_task} for #{task} (#{task.orocos_name})" }
                end
                work_plan.remove_task(deployment_task)
                applied_merges
            end

            # Computes the set of requirement tasks that should be used for
            # deployment within the given plan
            def self.discover_requirement_tasks_from_plan(plan)
                req_tasks = plan.find_local_tasks(InstanceRequirementsTask)
                req_tasks = req_tasks.find_all do |req_task|
                    if req_task.failed? || req_task.pending?
                        false
                    elsif planned_task = req_task.planned_task
                        !planned_task.finished? || planned_task.being_repaired?
                    else
                        false
                    end
                end
                needed = plan.useful_tasks(with_transactions: false)
                req_tasks.delete_if do |t|
                    !needed.include?(t)
                end
                req_tasks
            end

            def compute_system_network(requirement_tasks = Engine.discover_requirement_tasks_from_plan(real_plan),
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true)
                requirement_tasks = requirement_tasks.to_a
                instance_requirements = requirement_tasks.map(&:requirements)
                system_network_generator = SystemNetworkGenerator.new(
                    work_plan, event_logger: event_logger, merge_solver: merge_solver
                )
                toplevel_tasks = system_network_generator.generate(
                    instance_requirements,
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network
                )

                Hash[requirement_tasks.zip(toplevel_tasks)]
            end

            # Computes the system network, that is the network that fullfills
            # a list of requirements
            #
            # This phase does not interact at all with {#real_plan}. It only
            # computes the canonical plan that matches the requirements.
            #
            # Its return value can then be given to
            # {#apply_system_network_to_plan} to adapt the current plan to the
            # desired state.
            #
            # @param [Array<InstanceRequirementsTask>] requirement_tasks the
            #   tasks that represent the requirements for the generated network
            # @param [Plan] plan the plan into which the network should be
            #   generated
            # @param [Boolean] garbage_collect whether the plan should be
            #   cleaned of unused tasks (debugging only)
            # @return [Hash<InstanceRequirementsTask,InstanceRequirementsTask>]
            #   mapping from a requirement task given to the method to the
            #   corresponding requirement task in the generated plan. In other
            #   words, the keys are in {#real_plan} and the values in
            #   {#work_plan}
            def resolve_system_network(
                requirement_tasks,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true,
                compute_deployments: true,
                default_deployment_group: Syskit.conf.deployment_group,
                compute_policies: true
            )

                required_instances = compute_system_network(
                    requirement_tasks,
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network
                )

                if compute_deployments
                    log_timepoint_group "compute_deployed_network" do
                        compute_deployed_network(
                            default_deployment_group: default_deployment_group,
                            compute_policies: compute_policies,
                            validate_deployed_network: validate_deployed_network
                        )
                    end
                end
                required_instances
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
            def resolve(requirement_tasks: Engine.discover_requirement_tasks_from_plan(real_plan),
                on_error: self.class.on_error,
                default_deployment_group: Syskit.conf.deployment_group,
                compute_deployments: true,
                compute_policies: true,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true,
                validate_final_network: true)

                required_instances = resolve_system_network(
                    requirement_tasks,
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network,
                    compute_deployments: compute_deployments,
                    default_deployment_group: default_deployment_group,
                    compute_policies: compute_policies,
                    validate_deployed_network: validate_deployed_network
                )

                apply_system_network_to_plan(
                    required_instances,
                    compute_deployments: compute_deployments,
                    garbage_collect: garbage_collect,
                    validate_final_network: validate_final_network
                )
            rescue Exception => e
                handle_resolution_exception(e, on_error: on_error)
                raise
            end

            def apply_system_network_to_plan(
                required_instances, compute_deployments: true,
                garbage_collect: true, validate_final_network: true
            )

                # Now, deploy the network by matching the available
                # deployments to the one in the generated network. Note that
                # these deployments are *not* yet the running tasks.
                #
                # The mapping from this deployed network to the running
                # tasks is done in #finalize_deployed_tasks
                if compute_deployments
                    log_timepoint_group "apply_deployed_network_to_plan" do
                        apply_deployed_network_to_plan
                    end
                end

                apply_merge_to_stored_instances
                required_instances = required_instances.transform_values do |task|
                    merge_solver.replacement_for(task)
                end
                log_timepoint "apply_merge_to_stored_instances"
                fix_toplevel_tasks(required_instances)
                log_timepoint "fix_toplevel_tasks"

                Engine.final_network_postprocessing.each do |block|
                    block.call(self, work_plan)
                    log_timepoint "final_network_postprocessing:#{block}"
                end

                # Finally, we should now only have deployed tasks. Verify it
                # and compute the connection policies
                if garbage_collect && validate_final_network
                    validate_final_network(required_instances, work_plan,
                                           compute_deployments: compute_deployments)
                    log_timepoint "validate_final_network"
                end

                commit_work_plan
            end

            def commit_work_plan
                work_plan.commit_transaction
                log_timepoint "commit_transaction"

                # Update the work plan's expected policies
                if @dataflow_dynamics
                    real_flow_graph = real_plan.task_relation_graph_for(Flows::DataFlow)
                    work_flow_graph = work_plan.task_relation_graph_for(Flows::DataFlow)
                    real_flow_graph.policy_graph =
                        work_flow_graph
                        .policy_graph
                        .transform_keys do |(source_t, sink_t)|
                            [work_plan.may_unwrap(merge_solver.replacement_for(source_t)),
                             work_plan.may_unwrap(merge_solver.replacement_for(sink_t))]
                        end
                end

                # Reset the oroGen model on all already-running tasks
                real_plan.find_tasks(Syskit::TaskContext).each do |task|
                    if (orocos_task = task.orocos_task) && orocos_task.respond_to?(:model=)
                        task.orocos_task.model = task.model.orogen_model
                    end
                end
            end

            def handle_resolution_exception(e, on_error: :discard)
                if !work_plan.finalized? && (work_plan != real_plan) # we started processing, look at what the user wants to do with the partial transaction
                    if on_error == :save
                        log_pp(:fatal, e)
                        fatal "Engine#resolve failed"
                        begin
                            dataflow_path, hierarchy_path = Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                            fatal "the generated plan has been saved"
                            fatal "use dot -Tsvg #{dataflow_path} > #{dataflow_path}.svg to convert the dataflow to SVG"
                            fatal "use dot -Tsvg #{hierarchy_path} > #{hierarchy_path}.svg to convert to SVG"
                        rescue Exception => e
                            Roby.log_exception_with_backtrace(e, self, :fatal)
                        end
                    end

                    if on_error == :commit
                        work_plan.commit_transaction
                    else
                        work_plan.discard_transaction
                    end
                end
            end

            # Validates the state of the network at the end of #resolve
            def validate_final_network(required_instances, plan, compute_deployments: true)
                # Check that all device instances are proper tasks (not proxies)
                required_instances.each do |req_task, task|
                    if task.transaction_proxy?
                        raise InternalError, "instance definition #{instance} contains a transaction proxy: #{instance.task}"
                    elsif !task.plan
                        raise InternalError, "instance definition #{task} has been removed from plan"
                    end
                end

                super if defined? super
            end

            @@dot_index = 0
            def self.autosave_plan_to_dot(plan, dir = Roby.app.log_dir, prefix: nil, suffix: nil, **dot_options)
                dot_index = (@@dot_index += 1)
                dataflow_path = File.join(dir, format("syskit-plan-#{prefix}%04i#{suffix}.%s.dot", dot_index, "dataflow"))
                hierarchy_path = File.join(dir, format("syskit-plan-#{prefix}%04i#{suffix}.%s.dot", dot_index, "hierarchy"))
                File.open(dataflow_path, "w") do |io|
                    io.write Graphviz.new(plan).dataflow(dot_options)
                end
                File.open(hierarchy_path, "w") do |io|
                    io.write Graphviz.new(plan).hierarchy(dot_options)
                end
                [dataflow_path, hierarchy_path]
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                Graphviz.new(work_plan).to_file(kind, "svg", filename, *additional_args)
            end

            def to_dot_dataflow(remove_compositions = false, excluded_models = Set.new, annotations = ["connection_policy"])
                gen = Graphviz.new(work_plan)
                gen.dataflow(remove_compositions, excluded_models, annotations)
            end

            def to_dot(options)
                to_dot_dataflow(options)
            end

            def pretty_print(pp) # :nodoc:
                pp.text "-- Tasks"
                pp.nest(2) do
                    pp.breakable
                    work_plan.each_task do |task|
                        pp.text task.to_s
                        pp.nest(4) do
                            pp.breakable
                            pp.seplist(task.children.to_a) do |t|
                                pp.text t.to_s
                            end
                        end
                        pp.breakable
                    end
                end

                pp.breakable
                pp.text "-- Connections"
                pp.nest(4) do
                    pp.breakable
                    work_plan.task_relation_graph_for(Flows::DataFlow).each_edge do |from, to, info|
                        pp.text from.to_s
                        pp.breakable
                        pp.text "  => #{to} (#{info})"
                        pp.breakable
                    end
                end
            end
        end
    end
end
