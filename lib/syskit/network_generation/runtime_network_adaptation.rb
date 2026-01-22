# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # Encapsulation of the part of the deployment algorithm that deals with
        # adapting the runtime network to match the system network
        class RuntimeNetworkAdaptation
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            attr_reader :event_logger

            # @param [{Component=>DeploymentGroup::DeployedTask}] used_deployments the
            #   mapping from task instances to the deployment used for it
            def initialize(
                work_plan, used_deployments,
                merge_solver:,
                event_logger: work_plan.event_logger,
                resolution_control: Async::Control.new
            )
                @work_plan = work_plan
                @event_logger = event_logger
                @resolution_control = resolution_control
                @merge_solver = merge_solver

                tasks_per_configured_deployments =
                    used_deployments.each_with_object({}) do |(task, deployed_task), h|
                        (h[deployed_task.configured_deployment] ||= []) << task
                    end
                @used_deployments =
                    tasks_per_configured_deployments.map do |configured_deployment, tasks|
                        UsedDeployment.new(
                            configured_deployment: configured_deployment, tasks: tasks
                        )
                    end
            end

            def apply
                result = finalize_deployed_tasks
                sever_old_plan_from_new_plan
                log_timepoint "syskit-netgen:sever-old-from-new-plan"
                result
            end

            def interruption_point(name, log_on_interruption_only: false)
                continue = @resolution_control.interruption_point(
                    self, name, log_on_interruption_only: log_on_interruption_only
                )
                throw :syskit_netgen_cancelled unless continue
            end

            # Given the network with deployed tasks, this method looks at how we
            # could adapt the running network to the new one
            def finalize_deployed_tasks
                finishing_deployments, existing_deployments =
                    import_from_runtime_plan
                interruption_point "syskit-netgen:apply:import-from-runtime-plan"

                used_deployments_with_existing =
                    used_deployments_find_existing(
                        @used_deployments, existing_deployments, finishing_deployments
                    )

                newly_deployed_tasks, reused_deployed_tasks, selected_deployment_tasks =
                    finalize_used_deployments(used_deployments_with_existing)

                debug do
                    debug "#{reused_deployed_tasks.size} tasks reused during deployment"
                    reused_deployed_tasks.each do |t|
                        debug "  #{t}"
                    end
                    break
                end

                # This is required to merge the already existing compositions
                # with the ones in the plan
                @merge_solver.merge_compositions
                log_timepoint "syskit-netgen:merge"

                [selected_deployment_tasks, reused_deployed_tasks | newly_deployed_tasks]
            end

            def import_from_runtime_plan
                used_tasks = @work_plan.find_local_tasks(Component).to_set

                all_tasks = import_existing_tasks
                interruption_point "syskit-netgen:apply:imported-existing-tasks"
                imported_tasks_remove_direct_connections(all_tasks - used_tasks)

                finishing_deployments, existing_deployments =
                    import_existing_deployments(@used_deployments)

                [finishing_deployments, existing_deployments]
            end

            # Find existing deployment tasks and finishing deployment tasks for the
            # system's used deployments
            #
            # @return an array of 3-tuples (deployment_task, existing_deployment_task,
            #   finishing_deployment)
            def used_deployments_find_existing(
                used_deployments, existing_deployments, finishing_deployments
            )
                used_deployments.map do |deployment_task|
                    # Check for the corresponding task in the plan
                    process_name = deployment_task.process_name
                    existing_deployment_tasks = existing_deployments[process_name] || []

                    if existing_deployment_tasks.size > 1
                        raise InternalError,
                              "more than one task for #{process_name} " \
                              "present in the plan: #{existing_deployment_tasks}"
                    end

                    [deployment_task, existing_deployment_tasks.first,
                     finishing_deployments[process_name]]
                end
            end

            # Make sure that the tasks that need to be deployed in the work plan are
            # actually deployed
            def finalize_used_deployments(used_deployments_with_existing)
                newly_deployed_tasks = Set.new
                reused_deployed_tasks = Set.new
                selected_deployment_tasks = Set.new
                used_deployments_with_existing.each do |deployment, existing, finishing|
                    selected, new, reused =
                        handle_required_deployment(deployment, existing, finishing)

                    newly_deployed_tasks.merge(new)
                    reused_deployed_tasks.merge(reused)
                    selected_deployment_tasks << selected
                    interruption_point(
                        "syskit-netgen:apply:select-deployment",
                        log_on_interruption_only: true
                    )
                end
                log_timepoint "syskit-netgen:selected-deployments"

                reused_deployed_tasks =
                    reconfigure_tasks_on_static_port_modification(reused_deployed_tasks)
                log_timepoint(
                    "syskit-netgen:reconfigure_tasks_on_static_port_modification"
                )

                [newly_deployed_tasks, reused_deployed_tasks, selected_deployment_tasks]
            end

            # Process a single deployment in {#finalize_deployed_tasks}
            #
            # @param [Syskit::Deployment] required the deployment task, part of
            #   the new network
            # @param [Syskit::Deployment,nil] usable usable deployment candidate
            #   found in the running plan
            # @param [Syskit::Deployment,nil] not_reusable deployment instance found
            #   in the running plan, matching required, but not reusable. Both usable
            #   and not_reusable may be non-nil if usable is pending. It is not possible
            #   otherwise (can't have the same deployment running twice)
            def handle_required_deployment(required, usable, not_reusable)
                debug do
                    debug "  looking to reuse a deployment for " \
                          "#{required.process_name} (#{required})"
                    debug "  candidate: #{usable}"
                    debug "  not reusable deployment: #{not_reusable}"
                    break
                end

                if usable
                    usable, not_reusable = validate_usable_deployment(
                        required, usable, not_reusable
                    )
                end

                if usable
                    newly_deployed_tasks = []
                    reused_deployed_tasks = adapt_existing_deployment(required, usable)
                    selected = usable
                else
                    reused_deployed_tasks = []
                    selected, newly_deployed_tasks = handle_new_deployment(required)
                end

                if not_reusable
                    @work_plan.unmark_permanent_task(not_reusable)
                    not_reusable.scheduled_for_kill!
                    selected.should_start_after(not_reusable.stop_event)
                end
                [selected, newly_deployed_tasks, reused_deployed_tasks]
            end

            # Handle new deployments for {#handle_required_deployment}
            #
            # In the old deployment method (the "eager" deployment), this is essentially
            # a no-op. In the new method (the "lazy" method), this is where new
            # deployments get created and replace the tasks
            def handle_new_deployment(required)
                executed_tasks = required.each_executed_task.to_a
                lazily_deployed_tasks = executed_tasks.find_all { !_1.execution_agent }

                if lazily_deployed_tasks.empty?
                    deployment_task = executed_tasks.first.execution_agent
                    return [deployment_task, executed_tasks]
                elsif lazily_deployed_tasks.size != executed_tasks.size
                    raise InternalError,
                          "in #handle_new_deployment: some tasks are deployed and some " \
                          "are not"
                end

                used_deployment_instanciate(required)
            end

            # Instanciate a UsedDeployment
            def used_deployment_instanciate(required)
                deployment_task = required.configured_deployment.new
                if Syskit.conf.permanent_deployments?
                    @work_plan.add_permanent_task(deployment_task)
                else
                    @work_plan.add_task(deployment_task)
                end

                deployed_tasks = required.tasks.map do |initial_deployed_task|
                    deployed_task = deployment_task.task(
                        initial_deployed_task.orocos_name,
                        setup_scheduler: false
                    )

                    # !!! Cf. comment in SystemNetworkDeployer#apply_selected_deployments
                    @merge_solver.apply_merge_group(
                        initial_deployed_task => deployed_task
                    )
                    deployed_task
                end

                [deployment_task, deployed_tasks]
            end

            # Validate that the usable deployment we found is actually usable
            #
            # @see existing_deployment_needs_restart?
            def validate_usable_deployment(required, usable, non_reusable)
                # Check if the existing deployment would need to be restarted
                # because of quarantine/fatal error tasks
                needs_restart = existing_deployment_needs_restart?(required, usable)
                return [usable, non_reusable] unless needs_restart

                # non_reusable_deployment should be nil here. There should not
                # be one if the usable deployment is running, and it is running
                # since existing_deployment_needs_restart?  can't return true
                # for a pending deployment
                return [nil, usable] unless non_reusable

                raise InternalError,
                      "non-nil non_reusable_deployment found in #{__method__} while " \
                      "existing_deployment_needs_restart? returned true"
            end

            # Do deeper 'usability' checks for an existing deployment found for
            # a required one
            #
            # In some cases (quarantined tasks, FATAL_ERROR), an existing deployment
            # that seem reusable actually cannot. This check is dependent on which
            # task contexts are needed, which cannot be done within Deployment#reusable?
            #
            # @param [Syskit::Deployment] required the deployment part of the network
            #   being deployed
            # @param [Syskit::Deployment] existing the deployment part of the running
            #   plan that is being considered
            def existing_deployment_needs_restart?(required, existing)
                restart_enabled =
                    Syskit.conf.auto_restart_deployments_with_quarantines?
                return false unless restart_enabled
                unless existing.has_fatal_errors? || existing.has_quarantines?
                    return false
                end

                required.each_executed_task do |t|
                    return true if existing.task_context_in_fatal?(t.orocos_name)
                    return true if existing.task_context_quarantined?(t.orocos_name)
                end
                false
            end

            # Import the component objects that are already in the main plan
            #
            # The graphs are modified to handle the deployment of the network
            # being generated
            #
            # @param [Array<Syskit::Component>] used_tasks the tasks that are part of the
            #   new network
            def import_existing_tasks
                all_tasks = @work_plan.find_tasks(Component).to_set
                interruption_point "syskit-engine:imported-tasks"

                all_tasks.delete_if do |t|
                    if t.finished?
                        debug { "  clearing the relations of the finished task #{t}" }
                        t.remove_relations(Syskit::Flows::DataFlow)
                        t.remove_relations(Roby::TaskStructure::Dependency)
                        true
                    elsif t.transaction_proxy? && t.abstract?
                        @work_plan.remove_task(t)
                        true
                    end
                end
                interruption_point "syskit-engine:imported-tasks:cleanup"

                all_tasks
            end

            # Remove connections that are not forwarding connections (e.g.
            # composition exports)
            def imported_tasks_remove_direct_connections(tasks)
                dataflow_graph =
                    @work_plan.task_relation_graph_for(Syskit::Flows::DataFlow)
                tasks.each do |t|
                    dataflow_graph.in_neighbours(t).dup.each do |source_t|
                        connections = dataflow_graph.edge_info(source_t, t).dup
                        connections_remove_non_exports(t, source_t, connections)
                        if connections.empty?
                            dataflow_graph.remove_edge(source_t, t)
                        else
                            dataflow_graph.set_edge_info(source_t, t, connections)
                        end
                    end
                    interruption_point(
                        "syskit-engine:imported-tasks:dataflow-cleanup",
                        log_on_interruption_only: true
                    )
                end
            end

            # Remove the connections that do not represent a composition export
            # from the connection set
            #
            # @param [Hash] connections the connection hash as stored in the dataflow
            #   graph
            def connections_remove_non_exports(task, source_task, connections)
                connections.delete_if do |(source_port, sink_port), _policy|
                    both_output = source_task.find_output_port(source_port) &&
                                  task.find_output_port(sink_port)
                    both_input  = source_task.find_input_port(source_port) &&
                                  task.find_input_port(sink_port)
                    !both_output && !both_input
                end
            end

            # Import all non-finished deployments from the actual plan into the
            # work plan, and sort them into those we can use and those we can't
            def import_existing_deployments(used_deployments)
                deployments = @work_plan.find_tasks(Syskit::Deployment).not_finished
                used_deployments.to_set(&:process_name)

                finishing_deployments = {}
                existing_deployments = {}
                deployments.each do |task|
                    process_name = task.process_name
                    if !task.reusable?
                        finishing_deployments[process_name] = task
                    elsif task.transaction_proxy?
                        (existing_deployments[process_name] ||= []) << task
                    end
                end

                [finishing_deployments, existing_deployments]
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
                already_setup_tasks =
                    find_all_setup_tasks.find_all { deployed_tasks.include?(_1) }

                already_setup_tasks.each do |t|
                    next unless t.transaction_modifies_static_ports?

                    debug do
                        "#{t} was selected as deployment, but it would require " \
                            "modifications on static ports, spawning a new task"
                    end

                    new_task = reconfigure_task(t)
                    final_deployed_tasks.delete(t)
                    final_deployed_tasks << new_task
                end
                final_deployed_tasks
            end

            def find_all_setup_tasks
                @work_plan
                    .find_tasks(Syskit::TaskContext).not_finished.not_finishing
                    .find_all { |t| !t.read_only? }
                    .find_all { |t| t.setting_up? || t.setup? }
            end

            def reconfigure_task(task)
                new_task = task.execution_agent.task(
                    task.orocos_name, task.concrete_model
                )
                @merge_solver.apply_merge_group(task => new_task)
                new_task.should_configure_after task.stop_event
                new_task
            end

            # Find the "last" deployed task in a set of related deployed tasks
            # in the plan
            #
            # Ordering is encoded in the should_configure_after relation
            def find_current_deployed_task(deployed_tasks)
                configuration_precedence_graph = @work_plan.event_relation_graph_for(
                    Roby::EventStructure::SyskitConfigurationPrecedence
                )

                tasks = deployed_tasks.find_all do |t|
                    configuration_precedence_graph.leaf?(t.stop_event)
                end

                if tasks.size > 1
                    raise InternalError,
                          "could not find the current task in " \
                          "#{deployed_tasks.map(&:to_s).sort.join(', ')}"
                end

                tasks.first
            end

            # Given a required deployment task in {#work_plan} and a proxy
            # representing an existing deployment task in {#real_plan}, modify
            # the plan to reuse the existing deployment
            #
            # @param [UsedDeployment] used_deployment
            # @return [Array<Syskit::TaskContext>] the set of TaskContext
            #   instances that have been used to replace the task contexts
            #   generated during network generation. They are all deployed by
            #   existing_deployment_task, and some of them might be transaction
            #   proxies.
            def adapt_existing_deployment(used_deployment, existing_deployment_task)
                orocos_name_to_existing =
                    adapt_existing_create_orocos_name_mapping(existing_deployment_task)

                applied_merges = Set.new
                deployed_tasks = used_deployment.each_executed_task.to_a
                initial_deployment_task = deployed_tasks.first.execution_agent
                deployed_tasks.each do |task|
                    existing_tasks =
                        orocos_name_to_existing[task.orocos_name] || []
                    existing_task = adapt_existing_deployed_task(
                        task, existing_tasks, existing_deployment_task
                    )
                    applied_merges << existing_task
                    debug { "  using #{existing_task} for #{task} (#{task.orocos_name})" }
                end
                @work_plan.remove_task(initial_deployment_task) if initial_deployment_task
                applied_merges
            end

            # Make sure a task from the work plan is deployed
            #
            # It can either re-use an existing deployed task from `existing_tasks`, or
            # create a new one if needed
            #
            # @return [TaskContext] the used task instance
            def adapt_existing_deployed_task(
                task, existing_tasks, existing_deployment_task
            )
                existing_task = find_current_deployed_task(existing_tasks)
                return if task == existing_task

                if !existing_task || !task.can_be_deployed_by?(existing_task)
                    new_task = adapt_existing_create_new(
                        task, existing_task, existing_deployment_task
                    )
                    adapt_existing_synchronize_new(new_task, existing_tasks)
                    existing_task = new_task
                end

                @merge_solver.apply_merge_group(task => existing_task)
                existing_task
            end

            # Create a string-to-tasks mapping for the existing executed tasks of a
            # deployment
            #
            # @return [{String=>Array<TaskContext>}] the mapping, where a name can be
            #   mapped to more than one task because of possible reconfigurations
            def adapt_existing_create_orocos_name_mapping(deployment_task)
                deployment_task.each_executed_task.with_object({}) do |t, h|
                    next if t.finished?

                    (h[t.orocos_name] ||= []) << t
                end
            end

            # Create a new deployed task within {#adapt_existing_deployment}
            def adapt_existing_create_new(task, existing_task, existing_deployment_task)
                debug do
                    if existing_task
                        "  task #{task.orocos_name} has been deployed, but " \
                            "I can't merge with the existing deployment " \
                            "(#{existing_task})"
                    else
                        "  task #{task.orocos_name} has not yet been deployed"
                    end
                end

                new_task =
                    existing_deployment_task
                    .task(task.orocos_name, task.concrete_model, setup_scheduler: false)

                debug do
                    "  created #{new_task} for #{task} (#{task.orocos_name})"
                end
                new_task
            end

            # Make sure a new task instance is configured only when previous one
            # in {#adapt_existing_deployment}
            def adapt_existing_synchronize_new(new_task, existing_tasks)
                existing_tasks.each do |previous_task|
                    debug do
                        "  #{new_task} will wait for #{previous_task} " \
                            "to finish before reconfiguring"
                    end

                    new_task.should_configure_after(previous_task.stop_event)
                end
            end

            # "Cut" relations between the "old" plan and the new one
            #
            # At this stage, old components (task contexts and compositions)
            # that are not part of the new plan may still be child of bits of
            # the new plan. This happens if they are added as children of other
            # task contexts. The transformer does this to register dynamic
            # transformation producers
            #
            # This pass looks for all proxies of compositions and task contexts
            # that are not the target of a merge operation. When this happens,
            # we know that the component is not being reused, and we remove all
            # dependency relations where it is child and where the parent is
            # "useful"
            #
            # Note that we do this only for relations between Syskit
            # components. Relations with "plan" Roby tasks are updated because
            # we replace toplevel tasks.
            def sever_old_plan_from_new_plan
                old_tasks =
                    @work_plan
                    .find_local_tasks(Syskit::Component)
                    .find_all(&:transaction_proxy?)

                merge_leaves = @merge_solver.each_merge_leaf.to_set
                old_tasks.each do |old_task|
                    next if merge_leaves.include?(old_task)

                    parents =
                        old_task
                        .each_parent_task
                        .find_all { |t| merge_leaves.include?(t) }

                    parents.each { |t| t.remove_child(old_task) }
                end
            end

            UsedDeployment = Struct.new(
                :configured_deployment, :tasks, keyword_init: true
            ) do
                def process_name
                    configured_deployment.process_name
                end

                def each_executed_task(&block)
                    tasks.each(&block)
                end
            end

            def debug_output_used_deployments_with_existing(
                used_deployments_with_existing
            )
                return unless Roby.log_level_enabled?(self, :debug)

                debug "  Mapping deployments in the network to the existing ones"
                used_deployments_with_existing.each do |used, existing, _|
                    debug "    network:  #{used}"
                    debug "    existing: #{existing}"
                end
            end
        end
    end
end
