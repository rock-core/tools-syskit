# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # Generate a plan from a set of {InstanceRequirement} objects
        #
        # It generates the canonical, non-deployed, plan. It does not take care
        # of the adaptation of an existing plan into the generated one
        class SystemNetworkGenerator
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            attr_reader :plan,
                        :event_logger,
                        :merge_solver,
                        :default_deployment_group

            # The error handler to register and process resolution errors
            attr_reader :error_handler

            # Indicates if deployment stage happens within network generation
            def early_deploy?
                @early_deploy
            end

            def initialize(plan, # rubocop:disable Metrics/ParameterLists
                event_logger: plan.event_logger,
                merge_solver: MergeSolver.new(plan),
                default_deployment_group: nil,
                early_deploy: false,
                error_handler: RaiseErrorHandler.new)
                if merge_solver.plan != plan
                    raise ArgumentError,
                          "gave #{merge_solver} as merge solver, which applies on " \
                          "#{merge_solver.plan}. Was expecting #{plan}"
                end

                @plan = plan
                @event_logger = event_logger
                @merge_solver = merge_solver
                @default_deployment_group = default_deployment_group
                @early_deploy = early_deploy
                @error_handler = error_handler
            end

            # Generate the network in the plan
            #
            # @param [bool] validate_deployed_network controls whether or not the
            # deployed network is validated, when #early_deploy? is true
            #
            # @return [Hash<Syskit::Component=>Array<InstanceRequirements>>] the
            #   list of toplevel tasks mapped to the instance requirements it
            #   represents
            def generate(instance_requirements,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true)

                # We first generate a non-deployed network that fits all
                # requirements.
                log_timepoint_group "compute_system_network" do
                    compute_system_network(
                        instance_requirements,
                        garbage_collect: garbage_collect,
                        validate_abstract_network: validate_abstract_network,
                        validate_generated_network: validate_generated_network,
                        validate_deployed_network: validate_deployed_network
                    )
                end
            end

            def find_selected_device_in_hierarchy(argument_name, leaf_task, requirements)
                _, model, = leaf_task.requirements
                                     .resolved_dependency_injection
                                     .selection_for(nil, requirements)
                if model && (dev = model.arguments[argument_name])
                    return dev
                end

                devices = Set.new
                leaf_task.each_parent_task do |parent|
                    sel = find_selected_device_in_hierarchy(
                        argument_name, parent, requirements
                    )
                    devices << sel if sel
                end

                devices.first if devices.size == 1
            end

            # Try to autoallocate the devices in +task+ based on the information
            # in the instance requirements in the task's hierarchy
            def allocate_devices(task)
                Engine.debug do
                    Engine.debug "allocating devices on #{task} using"
                    break
                end

                task.model.each_master_driver_service do |srv|
                    next if task.find_device_attached_to(srv)

                    if dev = find_selected_device_in_hierarchy(:"#{srv.name}_dev", task, srv.model.to_instance_requirements)
                        Engine.debug do
                            Engine.debug "  selected #{dev} for #{srv.name}"
                        end
                        task.arguments[:"#{srv.name}_dev"] = dev
                    end
                end
            end

            # Create on {#plan} the task instances that are currently
            # required in {#real_plan}
            #
            # It does not try to merge the result, {#plan} is probably full
            # of redundancies after this call
            #
            # @return [void]
            def instanciate(instance_requirements)
                log_timepoint "instanciate_requirements"
                toplevel_tasks = instance_requirements.each_with_index.map do |requirements, i|
                    task = requirements.instanciate(plan).to_task
                    debug do
                        debug "Instanciated task "
                        log_nest(2) do
                            log_pp :debug, task
                        end
                        debug "for requirements "
                        log_pp :debug, requirements
                        nil
                    end
                    # We add all these tasks as permanent tasks, to use
                    # #static_garbage_collect to cleanup #plan.
                    plan.add_permanent_task(task)

                    fullfilled_task_m, fullfilled_modules, req_args =
                        requirements.fullfilled_model
                    meaningful_args = task.meaningful_arguments.dup
                    meaningful_args.delete_if { |k, _| !req_args.key?(k) }

                    task.fullfilled_model = [
                        fullfilled_task_m, fullfilled_modules, meaningful_args
                    ]
                    log_timepoint "task-#{i}"
                    task
                end

                plan.each_task do |task|
                    if task.respond_to?(:each_master_driver_service)
                        allocate_devices(task)
                    end
                end
                log_timepoint "device_allocation"
                toplevel_tasks
            end

            def required_busses_for(device_task)
                device_task.each_master_device.flat_map(&:com_busses).uniq
            end

            # Creates communication busses and links the tasks to them
            def link_to_busses
                # Get all the tasks that need at least one communication bus
                queue = plan.find_local_tasks(Syskit::Device).to_a

                bus_tasks = {}
                handled_tasks = Set.new
                until queue.empty?
                    task = queue.shift
                    next if handled_tasks.include?(task)

                    handled_tasks << task

                    required_busses_for(task).each do |bus_device|
                        unless (com_bus_task = bus_tasks[bus_device])
                            com_bus_task = bus_device.instanciate(plan)
                            bus_tasks[bus_device] = com_bus_task
                            queue << com_bus_task.component
                        end

                        com_bus_task = com_bus_task.component
                        com_bus_task.attach(task)
                        task.depends_on com_bus_task
                        task.should_configure_after com_bus_task.start_event
                    end
                end
                nil
            end

            def self.remove_abstract_composition_optional_children(plan)
                # Now remove the optional, non-resolved children of compositions
                plan.find_local_tasks(AbstractComponent).abstract.each do |task|
                    parent_tasks = task.each_parent_task.to_a
                    parent_tasks.each do |parent_task|
                        next unless parent_task.kind_of?(Syskit::Composition)
                        next if parent_task.abstract?

                        roles = parent_task.roles_of(task).dup
                        remaining_roles = roles.find_all do |child_role|
                            !(child_model = parent_task.model.find_child(child_role)) ||
                                !child_model.optional?
                        end
                        if remaining_roles.empty?
                            parent_task.remove_child(task)
                        else
                            parent_task.remove_roles(task, *(roles - remaining_roles))
                        end
                    end
                end
            end

            def deploy(deployment_tasks)
                network_deployer = SystemNetworkDeployer.new(
                    plan,
                    merge_solver: merge_solver,
                    default_deployment_group: default_deployment_group
                )

                network_deployer.deploy(validate: false,
                                        reuse_deployments: true,
                                        deployment_tasks: deployment_tasks)
            end

            def instanciate_system_network(instance_requirements)
                @toplevel_tasks = log_timepoint_group "instanciate" do
                    instanciate(instance_requirements)
                end
                Engine.instanciation_postprocessing.each do |block|
                    block.call(self, plan)
                    log_timepoint "postprocessing:#{block}"
                end
                @toplevel_instance_requirements = instance_requirements
                @toplevel_tasks
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def resolve_system_network(error_handler: @error_handler,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true)
                deployment_tasks = {}
                deploy(deployment_tasks) if early_deploy?
                merge_solver.merge_identical_tasks
                log_timepoint "merge"
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, plan)
                    log_timepoint "postprocessing:#{block}"
                end

                link_to_busses
                log_timepoint "link_to_busses"

                deploy(deployment_tasks) if early_deploy?
                merge_solver.merge_identical_tasks
                log_timepoint "merge"

                self.class.remove_abstract_composition_optional_children(plan)
                log_timepoint "remove-optional"

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                plan.find_local_tasks(Component).each(&:freeze_delayed_arguments)
                log_timepoint "default_conf"

                # Cleanup the remainder of the tasks that are of no use right
                # now (mostly devices)
                if garbage_collect
                    plan.static_garbage_collect do |obj|
                        debug { "  removing #{obj}" }
                        # Remove tasks that we just added and are not
                        # useful anymore
                        plan.remove_task(obj)
                    end
                    log_timepoint "static_garbage_collect"
                end

                # And get rid of the 'permanent' marking we use to be able to
                # run static_garbage_collect
                plan.permanent_tasks
                    .find_all { |task| !task.kind_of?(Syskit::Deployment) }
                    .each { |task| plan.unmark_permanent_task(task) }

                Engine.system_network_postprocessing.each do |block|
                    block.call(self, plan)
                end
                log_timepoint "postprocessing"

                validate_network(
                    error_handler: error_handler,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network,
                    validate_deployed_network:
                        early_deploy? && validate_deployed_network
                )
                @toplevel_tasks
            end

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network(instance_requirements,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true)
                error_handler = RaiseErrorHandler.new
                instanciate_system_network(instance_requirements)
                resolve_system_network(
                    error_handler: error_handler,
                    garbage_collect: garbage_collect,
                    validate_abstract_network: validate_abstract_network,
                    validate_generated_network: validate_generated_network,
                    validate_deployed_network: validate_deployed_network
                )
            end

            def validate_network(error_handler: @error_handler,
                validate_abstract_network: true,
                validate_generated_network: true,
                validate_deployed_network: true)
                if validate_abstract_network
                    self.validate_abstract_network
                    log_timepoint "validate_abstract_network"
                end

                if validate_generated_network
                    self.validate_generated_network(error_handler: error_handler)
                    log_timepoint "validate_generated_network"
                end
                return unless early_deploy? && validate_deployed_network

                self.validate_deployed_network(error_handler: error_handler)
                log_timepoint "validate_deployed_network"
            end

            def toplevel_tasks_to_requirements
                (@toplevel_tasks || [])
                    .map { |t| merge_solver.replacement_for(t) }
                    .zip(@toplevel_instance_requirements || [])
                    .each_with_object({}) { |(t, ir), h| (h[t] ||= []) << ir }
            end

            # Verifies that the task allocation is complete. Return any
            # resolution failure.
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @param [NetworkGeneration::ResolutionErrorHandler] error_handler the error
            #   handler object to capture or raise any exceptions
            # @param [Array<Syskit::Component>] components the list of all the abstract
            #   components
            # @return [Array] the resolution failures
            def self.verify_task_allocation(
                plan, error_handler: RaiseErrorHandler.new,
                components: plan.find_local_tasks(AbstractComponent)
            )
                still_abstract = components.find_all(&:abstract?)
                still_abstract.each do |task|
                    message =
                        "could not find implementation for the following abstract " \
                        "task: #{task}"
                    exception = TaskAllocationFailed.new(self, [task])
                    exception = exception.exception(message)
                    error_handler.register_resolution_failures_from_exception(
                        task, exception
                    )
                end
            end

            # Verifies that there are no multiple output - single input
            # connections towards ports that are not multiplexing ports
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [SpecError] if some abstract tasks are still in
            #   the plan
            def self.verify_no_multiplexing_connections(plan)
                task_contexts = plan.find_local_tasks(TaskContext).to_a
                task_contexts.each do |task|
                    seen = {}
                    task.each_concrete_input_connection do |source_task, source_port, sink_port, _|
                        port_model = task.model.find_input_port(sink_port)
                        next if port_model&.multiplexes?

                        if seen[sink_port]
                            seen_task, seen_port = seen[sink_port]
                            if [source_task, source_port] != [seen_task, seen_port]
                                raise SpecError, "#{task}.#{sink_port} is connected " \
                                                 "multiple times, at least to " \
                                                 "#{source_task}.#{source_port} and " \
                                                 "#{seen_task}.#{seen_port}"
                            end
                        end
                        seen[sink_port] = [source_task, source_port]
                    end
                end
            end

            # Verifies that the same device is not attached to more than one task in the
            # plan.
            #
            # @param [Array<Syskit::Component>] components the list of all the abstract
            #   components
            # @param [Hash<Syskit::Component, Syskit::InstanceRequirementTask]
            #   toplevel_tasks_to_requirements mappings of toplevel tasks to their
            #   instance requirements
            # @return [Array<InternalResolutionFailure] all resolution failures from the
            #   components due to a conflicting device allocation
            def self.verify_conflicting_device_allocation(
                components, toplevel_tasks_to_requirements = {},
                error_handler: RaiseErrorHandler.new
            )
                devices = {}
                components.each do |task|
                    task.each_master_device do |dev|
                        device_name = dev.full_name
                        if (old_task = devices[device_name])
                            allocation_err = ConflictingDeviceAllocation.new(
                                dev, task, old_task, toplevel_tasks_to_requirements
                            )
                            error_handler.register_resolution_failures_from_exception(
                                [task, old_task], allocation_err
                            )
                        else
                            devices[device_name] = task
                        end
                    end
                end
            end

            # Verifies that all tasks that are device drivers have at least one
            # device attached, and that the same device is not attached to more
            # than one task in the plan. Any resolution failure is stored and return.
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @param [Array<Syskit::Component>] toplevel_tasks the list of all the
            #   toplevel tasks
            # @param [NetworkGeneration::MergeSolver] merge_solver the merge solver object
            #    with records with the task replacements so far
            # @param [Hash<Syskit::Component, Syskit::InstanceRequirementTask]
            #   toplevel_tasks_to_requirements mappings of toplevel tasks to their
            #   instance requirements
            # @return [Array<InternalResolutionFailure] all resolution failures from the
            #   components due to bad device allocation
            def self.verify_device_allocation(
                plan, toplevel_tasks_to_requirements = {},
                error_handler: RaiseErrorHandler.new
            )
                components = plan.find_local_tasks(Syskit::Device).to_a

                # Check that all devices are properly assigned
                missing_devices, allocated_devices = components.partition do |t|
                    t.model.each_master_driver_service
                     .any? { |srv| !t.find_device_attached_to(srv) }
                end
                missing_devices.each do |driver_task|
                    allocation_err = DeviceAllocationFailed.new(plan, driver_task)
                    tasks = allocation_err.task_parents.values.flat_map do |dependency_info|
                        dependency_info.flat_map do |parent_info|
                            parent_info[1]
                        end
                    end
                    error_handler.register_resolution_failures_from_exception(
                        tasks, allocation_err
                    )
                end

                verify_conflicting_device_allocation(
                    allocated_devices, toplevel_tasks_to_requirements,
                    error_handler: error_handler
                )
            end

            def self.verify_all_deployments_are_unique(
                plan, toplevel_tasks_to_requirements, error_handler: RaiseErrorHandler.new
            )
                deployment_to_task_map = plan.find_local_tasks(Syskit::TaskContext)
                                             .group_by(&:orocos_name)

                using_same_deployment = deployment_to_task_map.select do |name, tasks|
                    # There cant be a conflict between tasks that have no deployment
                    name && tasks.size > 1
                end

                return if using_same_deployment.empty?

                message = "deployment used multiple times"
                using_same_deployment.each do |orocos_name, tasks|
                    exception = ConflictingDeploymentAllocation.new(
                        orocos_name, tasks, toplevel_tasks_to_requirements
                    )
                    exception = exception.exception(message)
                    error_handler.register_resolution_failures_from_exception(
                        tasks, exception
                    )
                end
            end

            # Validates the network generated by {#compute_system_network}
            #
            # It performs the tests that are only needed on an abstract network,
            # i.e. on a network in which some tasks are still abstract
            def validate_abstract_network(error_handler: @error_handler)
                self.class.verify_no_multiplexing_connections(plan)
                super if defined? super
            end

            # Validates the network generated by {#compute_system_network}
            def validate_generated_network(error_handler: @error_handler)
                self.class.verify_task_allocation(plan, error_handler: error_handler)

                self.class.verify_device_allocation(
                    plan, toplevel_tasks_to_requirements, error_handler: error_handler
                )
                super if defined? super
            end

            def validate_deployed_network(error_handler: @error_handler)
                self.class.verify_all_tasks_deployed(
                    plan, default_deployment_group, error_handler: error_handler
                )
                self.class.verify_all_deployments_are_unique(
                    plan, toplevel_tasks_to_requirements.dup, error_handler: error_handler
                )
                super if defined? super
            end

            def self.verify_all_tasks_deployed(
                plan, default_deployment_group, error_handler: RaiseErrorHandler.new
            )
                SystemNetworkDeployer.verify_all_tasks_deployed(
                    plan,
                    default_deployment_group,
                    error_handler: error_handler
                )
            end
        end
    end
end
