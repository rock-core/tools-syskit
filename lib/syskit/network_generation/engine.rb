# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # @api private
        #
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

            def initialize(
                plan,
                work_plan: Roby::Transaction.new(plan),
                event_logger: plan.event_logger,
                resolution_control: Async::Control.new
            )
                @real_plan = plan
                @work_plan = work_plan
                @event_logger = event_logger
                @resolution_control = resolution_control
                @merge_solver = NetworkGeneration::MergeSolver.new(
                    work_plan,
                    event_logger: event_logger,
                    resolution_control: resolution_control
                )
                @required_instances = {}
            end

            # Returns the set of deployments that are available for this network
            # generation
            def available_deployments
                Syskit.conf.deployments
            end

            def interruption_point(name, log_on_interruption_only: false)
                continue = @resolution_control.interruption_point(
                    self, name, log_on_interruption_only: log_on_interruption_only
                )
                throw :syskit_netgen_cancelled unless continue
            end

            # Transform the system network into a deployed network
            #
            # This does not access {#real_plan}
            def compute_deployed_network(
                toplevel_tasks_to_requirements,
                error_handler: RaiseErrorHandler.new,
                required_instances: [],
                default_deployment_group: Syskit.conf.deployment_group,
                compute_policies: true,
                lazy_deploy: Syskit.conf.lazy_deploy?,
                validate_deployed_network: true
            )
                resolution_errors = []
                log_timepoint_group "syskit-netgen:deploy-system-network" do
                    deployer = SystemNetworkDeployer.new(
                        work_plan,
                        event_logger: event_logger,
                        merge_solver: merge_solver,
                        default_deployment_group: default_deployment_group,
                        resolution_control: @resolution_control
                    )

                    deployer.deploy(
                        error_handler: error_handler, validate: validate_deployed_network,
                        lazy: lazy_deploy
                    )
                    resolution_errors = error_handler.process_failures(
                        required_instances, cleanup_failed_tasks: true
                    )
                    # Sanity check that the plan was properly cleaned up
                    SystemNetworkDeployer.verify_all_tasks_deployed(
                        work_plan, default_deployment_group, lazy: lazy_deploy
                    )
                    SystemNetworkGenerator.verify_all_deployments_are_unique(
                        work_plan, toplevel_tasks_to_requirements.dup
                    )
                end

                interruption_point(
                    "syskit-netgen:deployed-system-network",
                    log_on_interruption_only: true
                )

                # Now that we have a deployed network, we can compute the
                # connection policies and the port dynamics
                if compute_policies
                    @dataflow_dynamics = DataFlowDynamics.new(work_plan)
                    @port_dynamics = dataflow_dynamics.compute_connection_policies
                    @dataflow_dynamics.result.each do |task, dynamics|
                        task.trigger_information = dynamics
                    end
                    interruption_point "compute_connection_policies"
                end

                resolution_errors
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
                        adaptation = RuntimeNetworkAdaptation.new(
                            work_plan,
                            merge_solver: @merge_solver,
                            event_logger: @event_logger,
                            resolution_control: @resolution_control
                        )
                        adaptation.apply
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
            #
            # @yieldparam [SystemNetworkGenerator] generator
            # @yieldparam [Roby::Transaction] plan
            def self.register_instanciation_postprocessing(&block)
                instanciation_postprocessing << block
                Roby.disposable { instanciation_postprocessing.delete(block) }
            end

            # Registers a system-wide post-processing stage for augmenting the
            # system network instanciation. Unlike the instanciation
            # postprocessing stage, a first merge pass has been done on the
            # graph and it is therefore not final but well-formed.
            #
            # Postprocessing stages that configures the task(s) automatically
            # should be registered with #register_system_network_postprocessing
            #
            # @yieldparam [SystemNetworkGenerator] generator
            # @yieldparam [Roby::Transaction] plan
            def self.register_instanciated_network_postprocessing(&block)
                instanciated_network_postprocessing << block
                Roby.disposable { instanciated_network_postprocessing.delete(block) }
            end

            # Registers a system-wide post-processing stage for the system
            # network (i.e. the complete network before it gets merged with
            # deployed tasks). This post-processing block is meant to
            # automatically configure the tasks and/or dataflow, but not change
            # the task graph
            #
            # Postprocessing stages that change the task graph should be
            # registered with #register_instanciation_postprocessing
            #
            # @yieldparam [SystemNetworkGenerator] generator
            # @yieldparam [Roby::Transaction] plan
            def self.register_system_network_postprocessing(&block)
                system_network_postprocessing << block
                Roby.disposable { system_network_postprocessing.delete(block) }
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
            #
            # @yieldparam [Engine] engine
            # @yieldparam [Roby::Transaction] plan
            def self.register_deployment_postprocessing(&block)
                deployment_postprocessing << block
                Roby.disposable { deployment_postprocessing.delete(block) }
            end

            # Registers a system-wide post-processing stage for the final
            # network. This is the last stage before the last validation
            #
            # @yieldparam [Engine] engine
            # @yieldparam [Roby::Transaction] plan
            def self.register_final_network_postprocessing(&block)
                final_network_postprocessing << block
                Roby.disposable { final_network_postprocessing.delete(block) }
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
                return if required_instances.empty?

                replacement_filter =
                    Roby::Plan::ReplacementFilter
                    .new
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
                        # When using Syskit, a toplevel task might have more than
                        # one planning task - think different requirements that
                        # resolve to the same place in the network
                        actual_task.add_planning_task(req_task, {})
                    end
                end
            end

            # Computes the set of requirement tasks that should be used for
            # deployment within the given plan
            def self.discover_requirement_tasks_from_plan(plan)
                req_tasks =
                    plan.find_local_tasks(InstanceRequirementsTask).running
                req_tasks = req_tasks.find_all do |t|
                    planned_task = t.planned_task
                    next unless planned_task

                    !planned_task.finished? || planned_task.being_repaired?
                end.to_set
                needed = plan.useful_tasks(with_transactions: false).to_set
                req_tasks.intersection(needed)
            end

            def compute_system_network(
                requirement_tasks =
                    Engine.discover_requirement_tasks_from_plan(real_plan),
                error_handler: RaiseErrorHandler.new,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                default_deployment_group: Syskit.conf.deployment_group,
                early_deploy: Syskit.conf.early_deploy?,
                lazy_deploy: Syskit.conf.lazy_deploy?,
                validate_deployed_network: early_deploy && !lazy_deploy,
                cleanup_resolution_errors: true
            )
                requirement_tasks = requirement_tasks.to_a
                instance_requirements = requirement_tasks.map(&:requirements)
                merge_solver.merge_task_contexts_with_same_agent = early_deploy

                system_network_generator = SystemNetworkGenerator.new(
                    work_plan,
                    error_handler: error_handler,
                    event_logger: event_logger,
                    merge_solver: merge_solver,
                    default_deployment_group: default_deployment_group,
                    lazy_deploy: lazy_deploy,
                    early_deploy: early_deploy,
                    resolution_control: @resolution_control
                )
                toplevel_tasks =
                    system_network_generator.instanciate_system_network(
                        instance_requirements
                    )

                system_network_generator.resolve_system_network(
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network,
                    validate_deployed_network:
                        early_deploy && !lazy_deploy && validate_deployed_network
                )
                required_instances = Hash[requirement_tasks.zip(toplevel_tasks)]
                # Take toplevel tasks to requirements before cleanup
                toplevel_tasks_to_requirements =
                    system_network_generator.toplevel_tasks_to_requirements

                resolution_errors = error_handler.process_failures(
                    required_instances,
                    cleanup_failed_tasks: cleanup_resolution_errors
                )
                if cleanup_resolution_errors
                    # Sanity check that the plan was properly cleaned up
                    system_network_generator.validate_network(
                        error_handler: RaiseErrorHandler.new,
                        validate_abstract_network: validate_abstract_network,
                        validate_generated_network: validate_generated_network,
                        validate_deployed_network:
                            early_deploy && !lazy_deploy && validate_deployed_network
                    )
                end
                [required_instances, resolution_errors, toplevel_tasks_to_requirements]
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
                compute_policies: true,
                early_deploy: Syskit.conf.early_deploy?,
                lazy_deploy: Syskit.conf.lazy_deploy?,
                capture_errors_during_network_resolution:
                    Syskit.conf.capture_errors_during_network_resolution?,
                cleanup_resolution_errors: true
            )
                merge_solver.merge_task_contexts_with_same_agent = early_deploy

                error_handler = if capture_errors_during_network_resolution
                                    ResolutionErrorHandler.new(work_plan, merge_solver)
                                else
                                    RaiseErrorHandler.new
                                end
                required_instances, resolution_errors, toplevel_tasks_to_requirements =
                    compute_system_network(
                        requirement_tasks,
                        error_handler: error_handler,
                        garbage_collect: garbage_collect,
                        validate_abstract_network: validate_abstract_network,
                        validate_generated_network: validate_generated_network,
                        default_deployment_group:
                            (default_deployment_group if early_deploy),
                        validate_deployed_network: validate_deployed_network,
                        early_deploy: early_deploy && compute_deployments,
                        lazy_deploy: lazy_deploy && compute_deployments,
                        cleanup_resolution_errors: cleanup_resolution_errors
                    )

                if compute_deployments
                    log_timepoint_group "compute_deployed_network" do
                        deployment_resolution_errors =
                            compute_deployed_network(
                                toplevel_tasks_to_requirements,
                                error_handler: error_handler,
                                required_instances: required_instances,
                                default_deployment_group: default_deployment_group,
                                compute_policies: compute_policies,
                                lazy_deploy: lazy_deploy,
                                validate_deployed_network: validate_deployed_network
                            )
                        resolution_errors.concat(deployment_resolution_errors)
                    end
                end
                [required_instances, resolution_errors]
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
            def resolve(
                requirement_tasks: Engine.discover_requirement_tasks_from_plan(real_plan),
                on_error: self.class.on_error,
                default_deployment_group: Syskit.conf.deployment_group,
                compute_deployments: true,
                compute_policies: true,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true,
                validate_final_network: true,
                early_deploy: Syskit.conf.early_deploy?,
                capture_errors_during_network_resolution:
                    Syskit.conf.capture_errors_during_network_resolution?,
                cleanup_resolution_errors: on_error != :commit
            )
                merge_solver.merge_task_contexts_with_same_agent = early_deploy
                required_instances, resolution_errors = resolve_system_network(
                    requirement_tasks,
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network,
                    compute_deployments: compute_deployments,
                    default_deployment_group: default_deployment_group,
                    compute_policies: compute_policies,
                    validate_deployed_network: validate_deployed_network,
                    early_deploy: early_deploy,
                    capture_errors_during_network_resolution:
                        capture_errors_during_network_resolution,
                    cleanup_resolution_errors: cleanup_resolution_errors
                )

                # Can only be reached if the capture_error_during_network_resolution flag
                # is true
                if !resolution_errors.empty? && !cleanup_resolution_errors
                    exceptions = resolution_errors.map(&:original_exception)
                    handle_resolution_exception(exceptions, on_error: on_error)
                    return resolution_errors
                end

                apply_system_network_to_plan(
                    required_instances,
                    compute_deployments: compute_deployments,
                    garbage_collect: garbage_collect,
                    validate_final_network: validate_final_network
                )
                resolution_errors
            rescue Exception => e # rubocop:disable Lint/RescueException
                handle_resolution_exception(e, on_error: on_error)
                raise
            end

            def apply_system_network_to_plan(
                required_instances,
                compute_deployments: true,
                garbage_collect: true,
                validate_final_network: true
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

            def discard_work_plan
                work_plan.discard_transaction unless work_plan.finalized?
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
                    orocos_task = task.orocos_task
                    if orocos_task.respond_to?(:model=)
                        task.orocos_task.model = task.model.orogen_model
                    end
                end
            end

            def handle_resolution_exception(exceptions, on_error: :discard)
                return if work_plan.finalized? || work_plan == real_plan

                exceptions = [exceptions] unless exceptions.kind_of? Array
                if on_error == :save
                    exceptions.each do |e|
                        log_pp(:fatal, e)
                        fatal "Engine#resolve failed"
                        begin
                            dataflow_path, hierarchy_path =
                                Engine.autosave_plan_to_dot(work_plan, Roby.app.log_dir)
                            fatal "the generated plan has been saved"
                            fatal "use dot -Tsvg #{dataflow_path} > " \
                                  "#{dataflow_path}.svg to convert the dataflow to SVG"
                            fatal "use dot -Tsvg #{hierarchy_path} > " \
                                  "#{hierarchy_path}.svg to convert to SVG"
                        rescue Exception => e # rubocop:disable Lint/RescueException
                            Roby.log_exception_with_backtrace(e, self, :fatal)
                        end
                    end
                elsif on_error == :commit
                    work_plan.commit_transaction
                else
                    discard_work_plan
                end
            end

            # Validates the state of the network at the end of #resolve
            def validate_final_network(
                required_instances, plan, compute_deployments: true
            )
                # Check that all device instances are proper tasks (not proxies)
                required_instances.each do |_req_task, task|
                    if task.transaction_proxy?
                        raise InternalError,
                              "instance definition #{instance} contains a transaction " \
                              "proxy: #{instance.task}"
                    elsif !task.plan
                        raise InternalError,
                              "instance definition #{task} has been removed from plan"
                    end
                end

                super if defined? super
            end

            @@dot_index = 0
            def self.autosave_plan_to_dot(
                plan, dir = Roby.app.log_dir, prefix: nil, suffix: nil, **dot_options
            )
                dot_index = (@@dot_index += 1)
                %w[dataflow hierarchy].map do |mode|
                    basename = format("syskit-plan-#{prefix}%04i#{suffix}.%s.dot",
                                      dot_index, mode)

                    path = File.join(dir, basename)
                    File.write(path, Graphviz.new(plan).send(mode, dot_options))
                    path
                end
            end

            # Generate a svg file representing the current state of the
            # deployment
            def to_svg(kind, filename = nil, *additional_args)
                Graphviz.new(work_plan).to_file(kind, "svg", filename, *additional_args)
            end

            def to_dot_dataflow(
                remove_compositions = false,
                excluded_models = Set.new,
                annotations = ["connection_policy"]
            )
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
                    flow_graph = work_plan.task_relation_graph_for(Flows::DataFlow)
                    flow_graph.each_edge do |from, to, info|
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
