module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            def setup
                @__test_created_deployments = Array.new
                @__test_overriden_configurations = Array.new
                super
            end

            def teardown
                super
                @__test_overriden_configurations.each do |model, manager|
                    model.configuration_manager = manager
                end
                @__test_created_deployments.each do |d|
                    Syskit.conf.deregister_configured_deployment(d)
                end
            end

            def protect_configuration_manager(model)
                manager = model.configuration_manager
                model.configuration_manager = manager.dup
                @__test_overriden_configurations << [model, manager]
            end

            def use_deployment(*args)
                @__test_created_deployments.concat(Syskit.conf.use_deployment(*args).to_a)
            end

            def use_ruby_tasks(*args)
                @__test_created_deployments.concat(Syskit.conf.use_ruby_tasks(*args).to_a)
            end

            # Run Syskit's deployer (i.e. engine) on the current plan
            def syskit_deploy(*to_instanciate, add_mission: true, syskit_engine: nil, **resolve_options, &block)
                syskit_engine ||= Syskit::NetworkGeneration::Engine.new(plan)
                syskit_engine.disable_updates

                # For backward-compatibility
                to_instanciate = to_instanciate.flatten

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
                            assert_event_emission(t.planning_task.success_event) do
                                t.planning_task.start!
                            end
                            to_instanciate << tracker.task
                        end
                    end
                end

                emit_calls = Set.new
                placeholder_tasks = to_instanciate.map do |act|
                    if act.respond_to?(:to_action)
                        act = act.to_action
                    end
                    plan.add(task = act.as_plan)
                    if add_mission
                        plan.add_mission(task)
                    end
                    task
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                requirement_tasks = placeholder_tasks.map(&:planning_task)

                plan.execution_engine.process_events_synchronous do
                    requirement_tasks.each { |t| t.start! }
                end

                syskit_engine.enable_updates
                begin
                    syskit_engine.resolve(**Hash[on_error: :commit].merge(resolve_options))
                rescue Exception => e
                    begin
                        plan.execution_engine.process_events_synchronous do
                            requirement_tasks.each { |t| t.failed_event.emit(e) }
                        end
                    rescue Roby::PlanningFailedError
                        # Emitting failed_event will cause the engine to raise
                        # PlanningFailedError
                    end
                    raise
                end

                plan.execution_engine.process_events_synchronous do
                    requirement_tasks.each { |t| t.success_event.emit if !t.finished? }
                end
                placeholder_tasks.each do |task|
                    plan.remove_object(task)
                end

                syskit_engine.format_timepoints.each do |*name, duration|
                    puts "%.3f %s" % [duration, name.join(" ")]
                end

                if Roby.app.public_logs?
                    filename = name.gsub("/", "_")
                    dataflow_base, hierarchy_base = filename + "-dataflow", filename + "-hierarchy"
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

                root_tasks = root_tasks.map(&:task)
                if root_tasks.size == 1
                    return root_tasks.first
                elsif root_tasks.size > 1
                    return root_tasks
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
            # @return [Model<Syskit::Deployment>] the deployment model. This
            #   deployment is declared as available on the 'stubs' process server,
            #   i.e. it can be started
            def syskit_stub_deployment_model(task_model = nil, name = nil, &block)
                if task_model
                    task_model = task_model.to_component_model
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

                Syskit.conf.process_server_for('stubs').
                    register_deployment_model(deployment_model.orogen_model)
                Syskit.conf.use_deployment(deployment_model.orogen_model, on: 'stubs')
                deployment_model
            end

            # Create a new stub deployment instance, optionally stubbing the
            # model as well
            def syskit_stub_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= syskit_stub_deployment_model(nil, name, &block)
                plan.add_permanent(task = deployment_model.new(process_name: name, on: 'stubs'))
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
            def syskit_stub_task_context(model, as: syskit_default_stub_name(model), devices: true)
                model = model.to_instance_requirements

                task_m = model.model.to_component_model
                if task_m.respond_to?(:proxied_data_services)
                    superclass = if task_m.superclass <= Syskit::TaskContext
                                     task_m.superclass
                                 else Syskit::TaskContext
                                 end

                    services = task_m.proxied_data_services
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

                concrete_task_m = task_m.concrete_model
                protect_configuration_manager(concrete_task_m)
                if conf = model.arguments[:conf]
                    conf.each do |conf_name|
                        concrete_task_m.configuration_manager.add(conf_name, Hash.new, merge: true)
                    end
                end

                syskit_stub_deployment_model(task_m, as)
                model.deployment_hints.clear
                model.prefer_deployed_tasks(as)
            end

            # @api private
            #
            # Helper for {#syskit_stub_model}
            #
            # @param [InstanceRequirements] model
            def syskit_stub_composition(model, recursive: true, as: syskit_default_stub_name(model), devices: true)
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
                                deployed_child = syskit_stub_composition(
                                    child_model, recursive: true, as: "#{as}_#{child_name}", devices: devices)
                            else
                                deployed_child = syskit_stub_task_context(
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
                syskit_stub(model.find_all_drivers.first || model, devices: false)
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
                    if !model.arguments["#{srv.name}_dev"]
                        model.with_arguments("#{srv.name}_dev" => syskit_stub_device(srv.model, driver: model.model))
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
                "#{self.name}_#{model_name}#{syskit_stub_model_id}"
            end

            # Create an InstanceRequirement instance that would allow to deploy
            # the given model
            def syskit_stub(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), devices: true, &block)
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                model = model.to_instance_requirements.dup

                if model.composition_model?
                    syskit_stub_composition(model, recursive: recursive, as: as, devices: devices)
                else
                    syskit_stub_task_context(model, as: as, devices: devices)
                end
            end

            def syskit_start_all_execution_agents
                plan.add_permanent(sync_ev = Roby::EventGenerator.new)

                agents = plan.each_task.map do |t|
                    if t.respond_to?(:should_configure_after)
                        t.should_configure_after(sync_ev)
                    end
                    if t.execution_agent && !t.execution_agent.ready?
                        t.execution_agent
                    end
                end.compact
                
                agents.each do |agent|
                    # Protect the component against configuration and 
                    if !agent.running?
                        agent.start!
                    end
                end

                agents.each do |agent|
                    if !agent.ready?
                        assert_event_emission agent.ready_event
                    end
                end
            ensure
                if sync_ev
                    plan.remove_object(sync_ev)
                end
            end

            def syskit_start_execution_agents(component, recursive: true)
                # Protect the component against configuration and startup
                plan.add_permanent(sync_ev = Roby::EventGenerator.new)
                component.should_configure_after(sync_ev)

                if recursive
                    component.each_child do |child_task|
                        syskit_start_execution_agents(child_task, recursive: true)
                    end
                end

                if agent = component.execution_agent
                    # Protect the component against configuration and 
                    if !agent.running?
                        agent.start!
                    end
                    if !agent.ready?
                        assert_event_emission agent.ready_event
                    end
                end
            ensure
                if sync_ev
                    plan.remove_object(sync_ev)
                end
            end

            def syskit_prepare_configure(component, tasks, sync_ev, recursive: true)
                component.should_start_after(sync_ev)
                component.freeze_delayed_arguments

                tasks << component

                if recursive
                    component.each_child do |child_task|
                        if child_task.respond_to?(:setup?)
                            syskit_prepare_configure(child_task, tasks, sync_ev, recursive: true)
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
            def syskit_configure(component, recursive: true)
                plan.add_permanent(sync_ev = Roby::EventGenerator.new)
                # We need all execution agents to be started to connect (and
                # therefore configur) the tasks
                syskit_start_all_execution_agents

                tasks = Set.new
                syskit_prepare_configure(component, tasks, sync_ev, recursive: recursive)

                pending = tasks.dup
                while !pending.empty?
                    Syskit::Runtime::ConnectionManagement.update(component.plan)
                    current_state = pending.size
                    pending.delete_if do |t|
                        if !t.setup? && t.ready_for_setup?
                            t.setup
                            t.is_setup!
                            true
                        else
                            t.setup?
                        end
                    end
                    if current_state == pending.size
                        raise NoConfigureFixedPoint.new(pending), "cannot configure #{pending.map(&:to_s).join(", ")}"
                    end
                end

                component

            ensure
                plan.remove_object(sync_ev)
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

            def syskit_prepare_start(component, tasks, recursive: true)
                tasks << component

                if recursive
                    component.each_child do |child_task|
                        if child_task.respond_to?(:setup?)
                            syskit_prepare_start(child_task, tasks, recursive: true)
                        end
                    end
                end
            end
            # Start this component
            def syskit_start(component, recursive: true)
                tasks = Set.new
                syskit_prepare_start(component, tasks, recursive: recursive)

                pending = tasks.dup
                while !pending.empty?
                    current_state = pending.size
                    pending.delete_if do |t|
                        if t.starting? || t.running?
                            true
                        elsif t.executable?
                            if !t.setup?
                                raise "#{t} is not set up, call #syskit_configure first"
                            end
                            t.start!
                            true
                        end
                    end

                    if current_state == pending.size
                        try_again = tasks.any? do |t|
                            if t.starting?
                                assert_event_emission t.start_event
                                true
                            end
                        end

                        if !try_again
                            raise NoStartFixedPoint.new(pending), "cannot start #{pending.map(&:to_s).join(", ")}"
                        end
                    end
                end

                tasks.each do |t|
                    if t.starting?
                        assert_event_emission t.start_event
                    end
                end

                if t = tasks.find { |t| !t.running? }
                    raise "#{t} #{t.starting?} #{t.running?} #{t.finished?}"
                end

                component
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
            def syskit_stub_and_deploy(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                model = syskit_stub(model, recursive: recursive, as: as, &block)
                syskit_deploy(model, compute_policies: false)
            end

            # Stub a task, deploy it and configure it
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_and_configure(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
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
            def syskit_stub_deploy_configure_and_start(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
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
            def syskit_configure_and_start(component = subject_syskit_model, recursive: true)
                component = syskit_configure(component, recursive: recursive)
                syskit_start(component, recursive: recursive)
            end
        end
    end
end

