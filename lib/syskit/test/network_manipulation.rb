module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            # Whether (false) the stub methods should resolve ruby tasks as ruby
            # tasks (i.e. Orocos::RubyTasks::TaskContext, the default), or
            # (true) as something that looks more like a remote task
            # (Orocos::RubyTasks::RemoteTaskContext)
            #
            # The latter is used in Syskit's own test suite to ensure that we
            # don't call remote methods from within Syskit's own event loop
            attr_predicate :syskit_stub_resolves_remote_tasks?, true

            def setup
                @__test_overriden_configurations = Array.new
                @__test_deployment_group = Models::DeploymentGroup.new
                @__orocos_writers = Array.new
                super
            end

            def teardown
                @__orocos_writers.each do |w|
                    w.disconnect
                end
                super
                @__test_overriden_configurations.each do |model, manager|
                    model.configuration_manager = manager
                end
            end

            # Ensure that any modification made to a model's configuration
            # manager are undone at teardown
            def syskit_protect_configuration_manager(model)
                manager = model.configuration_manager
                model.configuration_manager = manager.dup
                @__test_overriden_configurations << [model, manager]
            end

            def use_deployment(*args, **options)
                @__test_deployment_group.use_deployment(*args, **options)
            end

            def use_ruby_tasks(*args, **options)
                @__test_deployment_group.use_ruby_tasks(*args, **options)
            end

            def use_unmanaged_task(*args, **options)
                @__test_deployment_group.use_unmanaged_task(*args, **options)
            end

            # @api private
            #
            # Helper used to resolve writer objects
            def resolve_orocos_writer(writer)
                if writer.respond_to?(:to_orocos_port)
                    writer = Orocos.allow_blocking_calls do
                        writer.to_orocos_port
                    end
                end
                # We can write on LocalInputPort, LocalOutputPort and InputPort
                if writer.respond_to?(:writer)
                    writer = Orocos.allow_blocking_calls do
                        writer.writer
                    end
                elsif !writer.respond_to?(:write)
                    raise ArgumentError, "#{writer} does not seem to be a port "\
                        "one can write on"
                end
                writer
            end

            # Write a sample on a given input port
            def syskit_write(writer, sample)
                writer = resolve_orocos_writer(writer)
                @__orocos_writers << writer if writer.respond_to?(:disconnect)
                writer.write(sample)
            end

            def normalize_instanciation_models(to_instanciate)
                # Instanciate all actions until we have a syskit instance
                # requirement pattern
                while true
                    action_tasks, to_instanciate = to_instanciate.partition do |t|
                        t.respond_to?(:planning_task) &&
                            t.planning_task.pending? &&
                            !t.planning_task.respond_to?(:requirements)
                    end
                    if action_tasks.empty?
                        break
                    else
                        action_tasks.each do |t|
                            tracker = t.as_service
                            expect_execution { t.planning_task.start! }.
                                to { emit t.planning_task.start_event }
                            to_instanciate << tracker.task
                        end
                    end
                end
                to_instanciate
            end

            def syskit_generate_network(*to_instanciate, add_missions: true)
                to_instanciate = normalize_instanciation_models(to_instanciate)
                placeholders = to_instanciate.map(&:as_plan)
                if add_missions
                    execute do
                        placeholders.each do |t|
                            plan.add_mission_task(t)
                            if t.planning_task.pending?
                                t.planning_task.start_event.call
                            end
                        end
                    end
                end
                task_mapping = plan.in_transaction do |trsc|
                    engine = NetworkGeneration::Engine.new(plan, work_plan: trsc)
                    mapping = engine.compute_system_network(
                        placeholders.map(&:planning_task),
                        validate_generated_network: false)
                    trsc.commit_transaction
                    mapping
                end
                execute do
                    placeholders.map do |task|
                        replacement = task_mapping[task.planning_task]
                        plan.replace_task(task, replacement)
                        plan.remove_task(task)
                        replacement.planning_task.success_event.emit
                        replacement
                    end
                end
            end

            # Run Syskit's deployer (i.e. engine) on the current plan
            def syskit_deploy(*to_instanciate, add_mission: true, syskit_engine: nil, **resolve_options, &block)
                to_instanciate = to_instanciate.flatten # For backward-compatibility
                to_instanciate = normalize_instanciation_models(to_instanciate)

                placeholder_tasks = to_instanciate.map do |act|
                    act = act.to_action if act.respond_to?(:to_action)
                    plan.add(task = act.as_plan)
                    plan.add_mission_task(task) if add_mission
                    task
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                requirement_tasks = placeholder_tasks.map(&:planning_task)
                requirement_tasks.each do |task|
                    task.requirements.deployment_group.use_group!(@__test_deployment_group)
                end

                not_running = requirement_tasks.find_all { |t| !t.running? }
                expect_execution { not_running.each(&:start!) }.
                    to { emit *not_running.map(&:start_event) }

                resolve_options = Hash[on_error: :commit].merge(resolve_options)
                begin
                    syskit_engine_resolve_handle_plan_export do
                        syskit_engine ||= Syskit::NetworkGeneration::Engine.new(plan)
                        syskit_engine.resolve(**resolve_options)
                    end
                rescue Exception => e
                    expect_execution do
                        requirement_tasks.each { |t| t.failed_event.emit(e) }
                    end.to do
                        requirement_tasks.each do |t|
                            have_error_matching Roby::PlanningFailedError.match.
                                with_origin(t)
                        end
                    end
                    raise
                end

                execute do
                    placeholder_tasks.each do |task|
                        plan.remove_task(task)
                    end
                    requirement_tasks.each { |t| t.success_event.emit if !t.finished? }
                end

                root_tasks = root_tasks.map(&:task)
                if root_tasks.size == 1
                    return root_tasks.first
                elsif root_tasks.size > 1
                    return root_tasks
                end
            end

            def syskit_engine_resolve_handle_plan_export
                failed = false
                yield
            rescue Exception
                failed = true
                raise
            ensure
                if Roby.app.public_logs?
                    filename = name.gsub("/", "_")
                    dataflow_base, hierarchy_base = filename + "-dataflow", filename + "-hierarchy"
                    if failed
                        dataflow_base += "-FAILED"
                        hierarchy_base += "-FAILED"
                    end
                    dataflow = File.join(Roby.app.log_dir, "#{dataflow_base}.svg")
                    hierarchy = File.join(Roby.app.log_dir, "#{hierarchy_base}.svg")
                    while File.file?(dataflow) || File.file?(hierarchy)
                        i ||= 1
                        dataflow = File.join(Roby.app.log_dir, "#{dataflow_base}.#{i}.svg")
                        hierarchy = File.join(Roby.app.log_dir, "#{hierarchy_base}.#{i}.svg")
                        i = i + 1
                    end

                    Graphviz.new(plan).to_file('dataflow', 'svg', dataflow)
                    Graphviz.new(plan).to_file('hierarchy', 'svg', hierarchy)
                end
            end

            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def syskit_stub_task_context_model(name, &block)
                model = TaskContext.new_submodel(name: name, &block)
                model.orogen_model.extended_state_support
                model
            end

            def syskit_stub_configured_deployment(task_model = nil, name = nil,
                remote_task: syskit_stub_resolves_remote_tasks?, register: true, &block)

                if task_model
                    task_model = task_model.to_component_model
                end

                process_server = Syskit.conf.process_server_for('stubs')

                task_context_class =
                    if remote_task
                        Orocos::RubyTasks::RemoteTaskContext
                    else
                        process_server.task_context_class
                    end

                name ||= syskit_default_stub_name(task_model)
                deployment_model = Deployment.new_submodel(name: name) do
                    if task_model
                        task(name, task_model.orogen_model)
                    end
                    if block_given?
                        instance_eval(&block)
                    end
                end

                deployment = Models::ConfiguredDeployment.new(
                    'stubs', deployment_model, Hash[name => name], name,
                    Hash[task_context_class: task_context_class])
                if register
                    @__test_deployment_group.register_configured_deployment(deployment)
                end
                deployment
            end

            # Create a new stub deployment model that can deploy a given task
            # context model
            #
            # @param [Model<Syskit::TaskContext>,nil] task_model if given, a
            #   task model that should be deployed by this deployment model
            # @param [String] name the name of the deployed task as well as
            #   of the deployment. If not given, and if task_model is provided,
            #   task_model.name is used as default
            # @yield the deployment model context, i.e. a context in which the
            #   same declarations than in oroGen's #deployment statement are
            #   available
            # @return [Models::ConfiguredDeployment] the configured deployment
            def syskit_stub_deployment_model(
                    task_model = nil, name = nil,
                    remote_task: self.syskit_stub_resolves_remote_tasks?, &block)
                configured_deployment = syskit_stub_configured_deployment(task_model,
                    name, remote_task: remote_task, &block)
                configured_deployment.model
            end

            # Create a new stub deployment instance, optionally stubbing the
            # model as well
            def syskit_stub_deployment(
                    name = "deployment", deployment_model = nil,
                    remote_task: self.syskit_stub_resolves_remote_tasks?, &block)
                deployment_model ||= syskit_stub_deployment_model(nil, name, &block)
                plan.add_permanent_task(task = deployment_model.new(process_name: name, on: 'stubs'))
                task
            end

            def syskit_stub_component(model, devices: true)
                if devices
                    syskit_stub_required_devices(model)
                else
                    model
                end
            end

            # @api private
            #
            # Helper for {#syskit_stub_and_deploy}
            #
            # @param [InstanceRequirements] task_m the task context model
            # @param [String] as the deployment name
            def syskit_stub_task_context_requirements(model, as: syskit_default_stub_name(model), devices: true)
                model = model.to_instance_requirements

                task_m = model.model.to_component_model.concrete_model
                if task_m.placeholder?
                    superclass = if task_m.superclass <= Syskit::TaskContext
                                     task_m.superclass
                                 else Syskit::TaskContext
                                 end

                    services = task_m.proxied_data_service_models
                    task_m = superclass.new_submodel(name: "#{task_m.to_s}-stub")
                    services.each_with_index do |srv, idx|
                        srv.each_input_port do |p|
                            task_m.orogen_model.input_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        srv.each_output_port do |p|
                            task_m.orogen_model.output_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        if srv <= Syskit::Device
                            task_m.driver_for srv, as: "dev#{idx}"
                        else
                            task_m.provides srv, as: "srv#{idx}"
                        end
                    end
                elsif task_m.abstract?
                    task_m = task_m.new_submodel(name: "#{task_m.name}-stub")
                end
                model.add_models([task_m])
                model = syskit_stub_component(model, devices: devices)

                syskit_stub_conf(task_m, *model.arguments[:conf])

                deployment = syskit_stub_configured_deployment(task_m, as, register: false)
                model.reset_deployment_selection
                model.use_configured_deployment(deployment)
                model
            end

            # Create empty configuration sections for the given task model
            def syskit_stub_conf(task_m, *conf, data: Hash.new)
                concrete_task_m = task_m.concrete_model
                syskit_protect_configuration_manager(concrete_task_m)
                conf.each do |conf_name|
                    concrete_task_m.configuration_manager.add(conf_name, data, merge: true)
                end
            end

            # @api private
            #
            # Helper for {#syskit_stub_model}
            #
            # @param [InstanceRequirements] model
            def syskit_stub_composition_requirements(model, recursive: true, as: syskit_default_stub_name(model), devices: true)
                model = syskit_stub_component(model, devices: devices)

                if recursive
                    model.each_child do |child_name, selected_child|
                        if selected_task = selected_child.component
                            deployed_child = selected_task
                        else
                            child_model = selected_child.selected
                            selected_service = child_model.service
                            child_model = child_model.to_component_model
                            if child_model.composition_model?
                                deployed_child = syskit_stub_composition_requirements(
                                    child_model, recursive: true, as: "#{as}_#{child_name}", devices: devices)
                            else
                                deployed_child = syskit_stub_task_context_requirements(
                                    child_model, as: "#{as}_#{child_name}", devices: devices)
                            end
                            if selected_service
                                deployed_child.select_service(selected_service)
                            end
                        end
                        model.use(child_name => deployed_child)
                    end
                end

                model
            end

            # @api private
            #
            # Finds a driver model for a given device model, or create one if
            # there is none
            def syskit_stub_driver_model_for(model)
                syskit_stub_requirements(model.find_all_drivers.first || model, devices: false)
            end

            # Create a stub device of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<Device>] model the device model
            # @param [String] as the device name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def syskit_stub_device(model, as: syskit_default_stub_name(model), driver: nil, robot: nil, **device_options)
                robot ||= Syskit::Robot::RobotDefinition.new
                driver ||= syskit_stub_driver_model_for(model)
                robot.device(model, as: as, using: driver, **device_options)
            end

            # Create a stub combus of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<ComBus>] model the device model
            # @param [String] as the combus name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def syskit_stub_com_bus(model, as: syskit_default_stub_name(model), driver: nil, robot: nil, **device_options)
                robot ||= Syskit::Robot::RobotDefinition.new
                driver ||= syskit_stub_driver_model_for(model)
                robot.com_bus(model, as: as, using: driver, **device_options)
            end

            # Create a stub device attached on the given bus
            #
            # If the bus is a device object, the new device is attached to the
            # same robot model. Otherwise, a new robot model is created for both
            # the bus and the device
            #
            # @param [Model<ComBus>,MasterDeviceInstance] bus either a bus model
            #   or a bus object
            # @param [String] as a name for the new device
            # @param [Model<TaskContext>] driver the driver that should be used
            #   for the device. If not given, syskit will look for a suitable
            #   driver or stub one
            def syskit_stub_attached_device(bus, as: syskit_default_stub_name(bus))
                if !bus.kind_of?(Robot::DeviceInstance)
                    bus = syskit_stub_com_bus(bus, as: "#{as}_bus")
                end
                bus_m = bus.model
                dev_m = Syskit::Device.new_submodel(name: "#{bus}-stub") do
                    provides bus_m::ClientSrv
                end
                dev = syskit_stub_device(dev_m, as: as)
                dev.attach_to(bus)
                dev
            end

            # Stubs the devices required by the given model
            def syskit_stub_required_devices(model)
                model = model.to_instance_requirements
                model.model.to_component_model.each_master_driver_service do |srv|
                    if !model.arguments[:"#{srv.name}_dev"]
                        model.with_arguments(:"#{srv.name}_dev" => syskit_stub_device(srv.model, driver: model.model))
                    end
                end
                model
            end

            @@syskit_stub_model_id = -1

            def syskit_stub_model_id
                id = (@@syskit_stub_model_id += 1)
                if id != 0
                    id
                end
            end

            def syskit_default_stub_name(model)
                model_name =
                    if model.respond_to?(:name) then model.name
                    else model.to_str
                    end
                "stub#{syskit_stub_model_id}"
            end

            # @deprecated use syskit_stub_requirements instead
            def syskit_stub(*args, **options, &block)
                Roby.warn_deprecated "syskit_stub has been renamed to syskit_stub_requirements to make the difference with syskit_stub_network more obvious"
                syskit_stub_requirements(*args, **options, &block)
            end

            # Create an InstanceRequirement instance that would allow to deploy
            # the given model
            def syskit_stub_requirements(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), devices: true, &block)
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                model = model.to_instance_requirements.dup

                if model.composition_model?
                    syskit_stub_composition_requirements(model, recursive: recursive, as: as, devices: devices)
                else
                    syskit_stub_task_context_requirements(model, as: as, devices: devices)
                end
            end

            class CannotStub < RuntimeError
                def initialize(original, stub)
                    @original = original
                    @stub = stub
                    @semantic_merge_blockers = @original.arguments.
                        semantic_merge_blockers(@stub.arguments)
                end

                def pretty_print(pp)
                    pp.text "cannot stub "
                    @original.pretty_print(pp)

                    pp.breakable
                    if @semantic_merge_blockers.empty?
                        pp.text "The reason is unknown. Consider this a Syskit bug"
                        return
                    end

                    pp.text "The following delayed arguments should be made available"
                    pp.nest(2) do
                        @semantic_merge_blockers.each do |name, (arg, _)|
                            pp.breakable
                            pp.text "#{name} "
                            pp.nest(2) do
                                arg.pretty_print(pp)
                            end
                        end
                    end
                end
            end

            # Stub an already existing network
            def syskit_stub_network(root_tasks,
                                    remote_task: syskit_stub_resolves_remote_tasks?)
                mapped_tasks = plan.in_transaction do |trsc|
                    mapped_tasks = syskit_stub_network_in_transaction(
                        trsc, root_tasks, remote_task: remote_task
                    )
                    trsc.commit_transaction
                    mapped_tasks
                end

                execute do
                    syskit_stub_network_remove_obsolete_tasks(mapped_tasks)
                end
                root_tasks.map { |t, _| mapped_tasks[t] }
            end

            def syskit_stub_network_remove_obsolete_tasks(mapped_tasks)
                mapped_tasks.each do |old, new|
                    plan.remove_task(old) if old != new
                end
            end

            def syskit_stub_network_in_transaction(
                trsc, root_tasks,
                remote_task: syskit_stub_resolves_remote_tasks?
            )
                plan = trsc.plan
                tasks = Set.new
                dependency_graph = plan.task_relation_graph_for(Roby::TaskStructure::Dependency)
                root_tasks = Array(root_tasks).map do |t|
                    tasks << t
                    dependency_graph.depth_first_visit(t) do |child_t|
                        tasks << child_t
                    end

                    if plan.mission_task?(t)
                        [t, :mission_task]
                    elsif plan.permanent_task?(t)
                        [t, :permanent_task]
                    else
                        [t]
                    end
                end

                other_tasks = tasks.each_with_object(Set.new) do |t, s|
                    s.merge(t.each_parent_task)
                end
                other_tasks -= tasks
                trsc_other_tasks = other_tasks.map { |plan_t| trsc[plan_t] }

                merge_solver = NetworkGeneration::MergeSolver.new(trsc)
                trsc_tasks = tasks.map do |plan_t|
                    trsc_t = trsc[plan_t]
                    merge_solver.register_replacement(plan_t, trsc_t)
                    trsc_t
                end

                trsc_tasks.each do |task|
                    task.model.each_master_driver_service do |srv|
                        task.arguments[:"#{srv.name}_dev"] ||=
                            syskit_stub_device(srv.model, driver: srv)
                    end
                end

                stubbed_tags = {}
                merge_mappings = {}
                trsc_tasks.find_all(&:abstract?).each do |abstract_task|
                    # The task is required as being abstract (usually a
                    # if_already_present tag). Do not stub that
                    next if abstract_task.requirements.abstract?

                    concrete_task =
                        if abstract_task.kind_of?(Syskit::Actions::Profile::Tag)
                            tag_id = [abstract_task.model.tag_name,
                                      abstract_task.model.profile.name]
                            stubbed_tags[tag_id] ||=
                                syskit_stub_network_abstract_component(abstract_task)
                        else
                            syskit_stub_network_abstract_component(abstract_task)
                        end

                    pure_data_service_proxy =
                        abstract_task.placeholder? &&
                        !abstract_task.kind_of?(Syskit::TaskContext)
                    if pure_data_service_proxy
                        trsc.replace_task(abstract_task, concrete_task)
                        merge_solver.register_replacement(
                            abstract_task, concrete_task
                        )
                    else
                        merge_mappings[abstract_task] = concrete_task
                    end
                end

                # NOTE: must NOT call #apply_merge_group with merge_mappings
                # directly. #apply_merge_group "replaces" the subnet represented
                # by the keys with the subnet represented by the values. In
                # other words, the connections present between two keys would
                # NOT be copied between the corresponding values

                merge_mappings.each do |original, replacement|
                    unless replacement.can_merge?(original)
                        raise CannotStub.new(original, replacement),
                              "cannot stub #{original} with #{replacement}, maybe "\
                              'some delayed arguments are not set ?'
                    end
                    merge_solver.apply_merge_group(original => replacement)
                end
                merge_solver.merge_identical_tasks

                merge_mappings = {}
                trsc_tasks.each do |original_task|
                    concrete_task = merge_solver.replacement_for(original_task)
                    needs_new_deployment =
                        concrete_task.kind_of?(TaskContext) &&
                        !concrete_task.execution_agent
                    if needs_new_deployment
                        merge_mappings[concrete_task] =
                            syskit_stub_network_deployment(
                                concrete_task, remote_task: remote_task
                            )
                    end
                end

                merge_mappings.each do |original, replacement|
                    unless original.can_merge?(replacement)
                        raise CannotStub.new(original, replacement),
                              "cannot stub #{original} with #{replacement}, maybe "\
                              'some delayed arguments are not set ?'
                    end
                    # See big comment on apply_merge_group above
                    merge_solver.apply_merge_group(original => replacement)
                end

                mapped_tasks = {}
                tasks.each do |plan_t|
                    replacement_t = merge_solver.replacement_for(plan_t)
                    mapped_tasks[plan_t] = trsc.may_unwrap(replacement_t)
                end

                trsc_new_roots = Set.new
                root_tasks.each do |root_t, status|
                    replacement_t = mapped_tasks[root_t]
                    if replacement_t != root_t
                        unless replacement_t.planning_task
                            replacement_t.planned_by trsc[root_t.planning_task]
                        end
                        trsc.send("add_#{status}", replacement_t) if status
                    end
                    trsc_new_roots << trsc[replacement_t]
                end

                NetworkGeneration::SystemNetworkGenerator
                    .remove_abstract_composition_optional_children(trsc)
                trsc.static_garbage_collect(
                    protected_roots: trsc_new_roots | trsc_other_tasks
                )
                NetworkGeneration::SystemNetworkGenerator
                    .verify_task_allocation(trsc, components: trsc_tasks.find_all(&:plan))
                mapped_tasks
            end

            def syskit_stub_placeholder(model)
                superclass = if model.superclass <= Syskit::TaskContext
                                 model.superclass
                             else Syskit::TaskContext
                             end

                services = model.proxied_data_service_models
                task_m = superclass.new_submodel(name: "#{model.to_s}-stub")
                services.each_with_index do |srv, idx|
                    srv.each_input_port do |p|
                        task_m.orogen_model.input_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                    end
                    srv.each_output_port do |p|
                        task_m.orogen_model.output_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                    end
                    if srv <= Syskit::Device
                        task_m.driver_for srv, as: "dev#{idx}"
                    else
                        task_m.provides srv, as: "srv#{idx}"
                    end
                end
                task_m
            end

            def syskit_stub_network_abstract_component(task)
                task_m = task.concrete_model
                if task_m.placeholder?
                    task_m = syskit_stub_placeholder(task_m)
                elsif task_m.abstract?
                    task_m = task_m.new_submodel(name: "#{task_m.name}-stub")
                end

                arguments = task.arguments.dup
                task_m.each_master_driver_service do |srv|
                    arguments[:"#{srv.name}_dev"] ||=
                        syskit_stub_device(srv.model, driver: task_m)
                end
                task_m.new(**arguments)
            end

            def syskit_stub_network_deployment(
                    task, as: task.orocos_name || syskit_default_stub_name(task.model),
                    remote_task: self.syskit_stub_resolves_remote_tasks?)

                task_m = task.concrete_model
                deployment_model = syskit_stub_configured_deployment(
                    task_m, as, remote_task: remote_task, register: false)
                syskit_stub_conf(task_m, *task.arguments[:conf])
                task.plan.add(deployer = deployment_model.new)
                deployed_task = deployer.instanciate_all_tasks.first

                new_args = Hash.new
                task.arguments.find_all do |key, arg|
                    if deployed_task.arguments.writable?(key, arg)
                        new_args[key] = arg
                    end
                end
                deployed_task.assign_arguments(**new_args)
                deployed_task
            end

            def syskit_start_all_execution_agents
                guard = syskit_guard_against_configure

                agents = plan.each_task.map do |t|
                    if t.execution_agent && !t.execution_agent.ready?
                        t.execution_agent
                    end
                end.compact

                not_running = agents.find_all { |t| !t.running? }
                not_ready   = agents.find_all { |t| !t.ready? }
                expect_execution { not_running.each(&:start!) }.
                    to { emit(*not_ready.map(&:ready_event)) }

            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_start_execution_agents(component, recursive: true)
                guard = syskit_guard_against_start_and_configure

                not_ready = []

                queue = [component]
                while !queue.empty?
                    task = queue.shift
                    if (agent = task.execution_agent) && !agent.ready?
                        not_ready << agent
                    end
                    if recursive
                        queue.concat task.each_child.map { |t, _| t }
                    end
                end


                if !not_ready.empty?
                    expect_execution do
                        not_ready.each { |agent| agent.start! if !agent.running? }
                    end.to { emit(*not_ready.map(&:ready_event)) }
                end
            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_prepare_configure(component, tasks, recursive: true, except: Set.new)
                component.freeze_delayed_arguments

                if component.respond_to?(:setup?)
                    tasks << component
                end

                if recursive
                    component.each_child do |child_task|
                        if except.include?(child_task)
                            next
                        elsif child_task.respond_to?(:setup?)
                            syskit_prepare_configure(child_task, tasks, recursive: true, except: except)
                        end
                    end
                end
            end

            class NoConfigureFixedPoint < RuntimeError
                attr_reader :tasks
                attr_reader :info
                Info = Struct.new :ready_for_setup, :missing_arguments, :precedence, :missing

                def initialize(tasks)
                    @tasks = tasks
                    @info = Hash.new
                    tasks.each do |t|
                        precedence = t.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                        missing = precedence.find_all { |ev| !ev.emitted? }
                        info[t] = Info.new(
                            t.ready_for_setup?,
                            t.list_unset_arguments,
                            precedence, missing)
                    end
                end
                def pretty_print(pp)
                    pp.text "cannot find an ordering to configure #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)

                        info = self.info[t]
                        pp.nest(2) do
                            pp.breakable
                            pp.text "ready_for_setup? #{info.ready_for_setup}"
                            pp.breakable
                            if info.missing_arguments.empty?
                                pp.text "is fully instanciated"
                            else
                                pp.text "missing_arguments: #{info.missing_arguments.join(", ")}"
                            end

                            pp.breakable
                            if info.precedence.empty?
                                pp.text "has no should_configure_after constraint"
                            else
                                pp.text "is waiting for #{info.missing.size} events to happen before continuing, among #{info.precedence.size}"
                                pp.nest(2) do
                                    info.missing.each do |ev|
                                        pp.breakable
                                        ev.pretty_print(pp)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # Set this component instance up
            def syskit_configure(components = __syskit_root_components, recursive: true, except: Set.new)
                # We need all execution agents to be started to connect (and
                # therefore configur) the tasks
                syskit_start_all_execution_agents

                components = Array(components)
                return if components.empty?

                tasks = Set.new
                except  = except.to_set
                components.each do |component|
                    next if tasks.include?(component)
                    syskit_prepare_configure(component, tasks, recursive: recursive, except: except)
                end
                plan = components.first.plan
                guard = syskit_guard_against_start_and_configure(tasks)

                pending = tasks.dup.to_set
                while !pending.empty?
                    execute do
                        Syskit::Runtime::ConnectionManagement.update(plan)
                    end
                    current_state = pending.size
                    pending.delete_if do |t|
                        t.freeze_delayed_arguments
                        should_setup = Orocos.allow_blocking_calls do
                            !t.setup? && t.ready_for_setup?
                        end
                        if should_setup
                            messages = capture_log(t, :info) do
                                t.setup.execute
                                execution_engine.join_all_waiting_work
                            end
                            if t.failed_to_start?
                                raise t.failure_reason
                            else
                                assert t.setup?, "ran the setup for #{t}, but t.setup? does not return true"
                            end
                            true
                        else
                            t.setup?
                        end
                    end
                    if current_state == pending.size
                        missing_starts = pending.flat_map do |pending_task|
                            pending_task.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).
                                find_all { |e| e.symbol == :start && !e.emitted? }
                        end
                        missing_starts = missing_starts.map(&:task) - pending.to_a
                        if missing_starts.empty?
                            raise NoConfigureFixedPoint.new(pending), "cannot configure #{pending.map(&:to_s).join(", ")}"
                        else
                            syskit_start(missing_starts, recursive: false)
                        end
                    end
                end

            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            class NoStartFixedPoint < RuntimeError
                attr_reader :tasks

                def initialize(tasks)
                    @tasks = tasks
                end

                def pretty_print(pp)
                    pp.text "cannot find an ordering to start #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)
                    end
                end
            end

            def syskit_prepare_start(component, tasks, recursive: true, except: Set.new)
                if component.respond_to?(:setup?)
                    tasks << component
                end

                if recursive
                    component.each_child do |child_task|
                        if except.include?(child_task)
                            next
                        elsif child_task.respond_to?(:setup?)
                            syskit_prepare_start(child_task, tasks, recursive: true, except: except)
                        end
                    end
                end
            end

            def syskit_guard_against_configure(tasks = Array.new, guard = Roby::EventGenerator.new)
                tasks = Array(tasks)
                plan.add_permanent_event(guard)
                plan.find_tasks(Syskit::Component).each do |t|
                    if !t.setup? && !tasks.include?(t)
                        t.should_configure_after(guard)
                    end
                end
                guard
            end

            def syskit_guard_against_start_and_configure(tasks = Array.new, guard = Roby::EventGenerator.new)
                plan.add_permanent_event(guard)
                syskit_guard_against_configure(tasks, guard)

                plan.find_tasks(Syskit::Component).each do |t|
                    if t.pending? && !tasks.include?(t)
                        t.should_start_after(guard)
                    end
                end
                guard
            end

            def __syskit_root_components
                plan.find_tasks(Syskit::Component).not_abstract.roots(Roby::TaskStructure::Dependency)
            end

            # Start this component
            def syskit_start(components = __syskit_root_components, recursive: true, except: Set.new)
                components = Array(components)
                return if components.empty?

                tasks = Set.new
                except = except.to_set
                components.each do |component|
                    next if tasks.include?(component)
                    syskit_prepare_start(component, tasks, recursive: recursive, except: except)
                end
                plan = components.first.plan
                guard = syskit_guard_against_start_and_configure(tasks)

                messages = Hash.new { |h, k| h[k] = Array.new }
                tasks.each do |t|
                    flexmock(t).should_receive(:info).
                        and_return { |msg| messages[t] << msg }
                end

                pending = tasks.dup
                while !pending.empty?
                    current_state = pending.size

                    to_start = Array.new
                    pending.delete_if do |t|
                        if t.running?
                            true
                        elsif t.executable?
                            if !t.setup?
                                raise "#{t} is not set up, call #syskit_configure first"
                            end
                            to_start << t
                            true
                        end
                    end

                    if !to_start.empty?
                        expect_execution { to_start.each(&:start!) }.
                            to { emit(*to_start.map(&:start_event)) }
                    end

                    if current_state == pending.size
                        raise NoStartFixedPoint.new(pending), "cannot start #{pending.map(&:to_s).join(", ")}"
                    end
                end

                messages.each do |t, messages|
                    assert messages.include?("starting #{t}")
                end

                if t = tasks.find { |t| !t.running? }
                    raise RuntimeError, "failed to start #{t}: starting=#{t.starting?} running=#{t.running?} finished=#{t.finished?}"
                end

            ensure
                if guard
                    expect_execution do
                        plan.remove_free_event(guard)
                    end.to_run
                end
            end

            def syskit_wait_ready(writer_or_reader, component: writer_or_reader.port.to_actual_port.component)
                return if writer_or_reader.ready?

                if !component.setup?
                    syskit_configure(component)
                end
                if !component.running?
                    syskit_start(component)
                end

                expect_execution.to do
                    achieve { writer_or_reader.ready? }
                end
            end

            # Deploy the given composition, replacing every single data service
            # and task context by a ruby task context, allowing to then test.
            #
            # @param [Boolean] recursive (false) if true, the method will stub
            #   the children of compositions that are used by the root
            #   composition. Otherwise, you have to refer to them in the original
            #   instance requirements
            #
            # @example reuse toplevel tasks in children-of-children
            #   class Cmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #   end
            #   class RootCmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #      add Cmp, :as => 'processor'
            #   end
            #   model = RootCmp.use(
            #      'processor' => Cmp.use('pose' => RootCmp.pose_child))
            #   syskit_stub_deploy_and_start_composition(model)
            def syskit_stub_and_deploy(
                model = subject_syskit_model, recursive: true,
                    remote_task: self.syskit_stub_resolves_remote_tasks?, &block)

                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                tasks = syskit_generate_network(*model, &block)
                tasks = syskit_stub_network(tasks, remote_task: remote_task)
                if model.respond_to?(:to_ary)
                    tasks
                else
                    tasks.first
                end
            end

            # Stub a task, deploy it and configure it
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_and_configure(
                    model = subject_syskit_model, recursive: true,
                    as: syskit_default_stub_name(model),
                    remote_task: self.syskit_stub_resolves_remote_tasks?, &block)

                root = syskit_stub_and_deploy(model, recursive: recursive, remote_task: remote_task, &block)
                syskit_configure(root, recursive: recursive)
                root
            end

            # Stub a task, deploy it, configure it and start the task and
            # the underlying stub deployment
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_configure_and_start(
                    model = subject_syskit_model, recursive: true,
                    as: syskit_default_stub_name(model),
                    remote_task: self.syskit_stub_resolves_remote_tasks?, &block)

                root = syskit_stub_and_deploy(model, recursive: recursive, remote_task: remote_task, &block)
                syskit_configure_and_start(root, recursive: recursive)
                root
            end

            # Deploy and configure a model
            #
            # Unlike {#syskit_stub_deploy_and_configure}, it does not stub the
            # model, so model has to be deploy-able as-is.
            #
            # @param [#to_instance_requirements] model the requirements to
            #   deploy and configure
            # @param [Boolean] recursive if true, children of the provided model
            #   will be configured as well. Otherwise, only the toplevel task
            #   will
            # @return [Syskit::Component]
            def syskit_deploy_and_configure(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure(root, recursive: recursive)
                root
            end

            # Deploy, configure and start a model
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_deploy_configure_and_start(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure_and_start(root, recursive: recursive)
            end

            # Configure and start a task
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_configure_and_start(component = __syskit_root_components, recursive: true, except: Set.new)
                syskit_configure(component, recursive: recursive, except: except)
                syskit_start(component, recursive: recursive, except: except)
                component
            end

            # Export the dataflow and hierarchy to SVG
            def syskit_export_to_svg(plan = self.plan, suffix: '', dataflow_options: Hash.new, hierarchy_options: Hash.new)
                basename = 'syskit-export-%i%s.%s.svg'

                counter = 0
                Dir.glob('syskit-export-*') do |file|
                    if file =~ /syskit-export-(\d+)/
                        counter = [counter, Integer($1)].max
                    end
                end

                dataflow = basename % [counter + 1, suffix, 'dataflow']
                hierarchy = basename % [counter + 1, suffix, 'hierarchy']
                Syskit::Graphviz.new(plan).to_file('dataflow', 'svg', dataflow, **dataflow_options)
                Syskit::Graphviz.new(plan).to_file('hierarchy', 'svg', hierarchy, **hierarchy_options)
                puts "exported plan to #{dataflow} and #{hierarchy}"
                return dataflow, hierarchy
            end
        end
    end
end
