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

            attr_reader :plan
            attr_reader :event_logger
            attr_reader :merge_solver

            def initialize(plan,
                event_logger: plan.event_logger,
                merge_solver: MergeSolver.new(plan))
                if merge_solver.plan != plan
                    raise ArgumentError, "gave #{merge_solver} as merge solver, which applies on #{merge_solver.plan}. Was expecting #{plan}"
                end

                @plan = plan
                @event_logger = event_logger
                @merge_solver = merge_solver
            end

            # Generate the network in the plan
            #
            # @return [Hash<Syskit::Component=>Array<InstanceRequirements>>] the
            #   list of toplevel tasks mapped to the instance requirements it
            #   represents
            def generate(instance_requirements,
                garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true)

                # We first generate a non-deployed network that fits all
                # requirements.
                log_timepoint_group "compute_system_network" do
                    compute_system_network(instance_requirements,
                                           garbage_collect: garbage_collect,
                                           validate_abstract_network: validate_abstract_network,
                                           validate_generated_network: validate_generated_network)
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
                    task = requirements.instanciate(plan)
                                       .to_task
                    # We add all these tasks as permanent tasks, to use
                    # #static_garbage_collect to cleanup #plan.
                    plan.add_permanent_task(task)

                    fullfilled_task_m, fullfilled_modules, fullfilled_args =
                        requirements.fullfilled_model
                    fullfilled_args =
                        fullfilled_args.each_key.each_with_object({}) do |arg_name, h|
                            if task.arguments.set?(arg_name)
                                h[arg_name] = task.arguments[arg_name]
                            end
                        end

                    task.fullfilled_model = [
                        fullfilled_task_m, fullfilled_modules, fullfilled_args
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
                Engine.instanciation_postprocessing.each do |block|
                    block.call(self, plan)
                    log_timepoint "postprocessing:#{block}"
                end
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

            # Compute in #plan the network needed to fullfill the requirements
            #
            # This network is neither validated nor tied to actual deployments
            def compute_system_network(instance_requirements, garbage_collect: true,
                validate_abstract_network: true,
                validate_generated_network: true)
                toplevel_tasks = log_timepoint_group "instanciate" do
                    instanciate(instance_requirements)
                end

                merge_solver.merge_identical_tasks
                log_timepoint "merge"
                Engine.instanciated_network_postprocessing.each do |block|
                    block.call(self, plan)
                    log_timepoint "postprocessing:#{block}"
                end
                link_to_busses
                log_timepoint "link_to_busses"
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
                plan.each_task do |task|
                    plan.unmark_permanent_task(task)
                end

                Engine.system_network_postprocessing.each do |block|
                    block.call(self)
                end
                log_timepoint "postprocessing"

                if validate_abstract_network
                    self.validate_abstract_network
                    log_timepoint "validate_abstract_network"
                end
                if validate_generated_network
                    self.validate_generated_network
                    log_timepoint "validate_generated_network"
                end

                toplevel_tasks
            end

            # Verifies that the task allocation is complete
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [TaskAllocationFailed] if some abstract tasks are still in
            #   the plan
            def self.verify_task_allocation(
                plan, components: plan.find_local_tasks(AbstractComponent)
            )
                still_abstract = components.find_all(&:abstract?)
                return if still_abstract.empty?

                raise TaskAllocationFailed.new(self, still_abstract),
                      "could not find implementation for the following abstract "\
                      "tasks: #{still_abstract}"
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
                                raise SpecError, "#{task}.#{sink_port} is connected "\
                                                 "multiple times, at least to "\
                                                 "#{source_task}.#{source_port} and "\
                                                 "#{seen_task}.#{seen_port}"
                            end
                        end
                        seen[sink_port] = [source_task, source_port]
                    end
                end
            end

            # Verifies that all tasks that are device drivers have at least one
            # device attached, and that the same device is not attached to more
            # than one task in the plan
            #
            # @param [Roby::Plan] plan the plan on which we are working
            # @raise [DeviceAllocationFailed] if some device drivers are not
            #   attached to any device
            # @raise [SpecError] if some devices are assigned to more than one
            #   task
            def self.verify_device_allocation(plan)
                components = plan.find_local_tasks(Syskit::Device).to_a

                # Check that all devices are properly assigned
                missing_devices = components.find_all do |t|
                    t.model.each_master_driver_service
                     .any? { |srv| !t.find_device_attached_to(srv) }
                end
                unless missing_devices.empty?
                    raise DeviceAllocationFailed.new(plan, missing_devices),
                          "could not allocate devices for the following tasks: "\
                          "#{missing_devices}"
                end

                devices = {}
                components.each do |task|
                    task.each_master_device do |dev|
                        device_name = dev.full_name
                        if (old_task = devices[device_name])
                            raise ConflictingDeviceAllocation.new(dev, task, old_task)
                        else
                            devices[device_name] = task
                        end
                    end
                end
            end

            # Validates the network generated by {#compute_system_network}
            #
            # It performs the tests that are only needed on an abstract network,
            # i.e. on a network in which some tasks are still abstract
            def validate_abstract_network
                self.class.verify_no_multiplexing_connections(plan)
                super if defined? super
            end

            # Validates the network generated by {#compute_system_network}
            def validate_generated_network
                self.class.verify_task_allocation(plan)
                self.class.verify_device_allocation(plan)
                super if defined? super
            end
        end
    end
end
