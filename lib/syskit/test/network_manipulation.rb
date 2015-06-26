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
            def syskit_deploy(*to_instanciate, **resolve_options, &block)
                syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                syskit_engine.disable_updates

                # For backward-compatibility
                to_instanciate = to_instanciate.flatten

                placeholder_tasks = to_instanciate.map do |act|
                    if act.respond_to?(:to_action)
                        act = act.to_action
                    end
                    task = if act.respond_to?(:as_plan)
                               act.as_plan
                           else act.instanciate(plan)
                           end

                    if (planner = task.planning_task) && planner.respond_to?(:requirements)
                        plan.add_mission(task)
                        if !task.planning_task.running?
                            task.planning_task.start!
                        end
                        task
                    end
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                requirement_tasks = placeholder_tasks.map(&:planning_task)

                syskit_engine.enable_updates
                syskit_engine.resolve(**Hash[on_error: :commit].merge(resolve_options))

                requirement_tasks.each do |planning_task|
                    planning_task.emit :success
                end
                placeholder_tasks.each do |task|
                    plan.remove_object(task)
                end

                if Roby.app.public_logs?
                    filename = name.gsub("/", "_")
                    dataflow, hierarchy = filename + "-dataflow.svg", filename + "-hierarchy.svg"
                    Graphviz.new(plan).to_file('dataflow', 'svg', File.join(Roby.app.log_dir, dataflow))
                    Graphviz.new(plan).to_file('hierarchy', 'svg', File.join(Roby.app.log_dir, hierarchy))
                end
                if Roby.app.test_show_timings?
                    merge_timepoints(syskit_engine)
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
                    name ||= task_model.name
                end
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

            # @api private
            #
            # Helper for {#syskit_stub_and_deploy}
            #
            # @param [InstanceRequirements] task_m the task context model
            # @param [String] deployment_name the deployment name
            def syskit_stub_task_context(model, deployment_name)
                model = model.to_instance_requirements.dup
                task_m = model.model
                if task_m.respond_to?(:proxied_data_services)
                    superclass = if task_m.superclass <= Syskit::TaskContext
                                     task_m.superclass
                                 else Syskit::TaskContext
                                 end

                    services = task_m.proxied_data_services
                    task_m = superclass.new_submodel
                    services.each_with_index do |srv, idx|
                        srv.each_input_port do |p|
                            task_m.orogen_model.input_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        srv.each_output_port do |p|
                            task_m.orogen_model.output_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        task_m.provides srv, as: "srv#{idx}"
                    end
                elsif task_m.abstract?
                    task_m = task_m.new_submodel
                end
                model.add_models([task_m])

                concrete_task_m = task_m.concrete_model
                protect_configuration_manager(concrete_task_m)
                if conf = model.arguments[:conf]
                    conf.each do |conf_name|
                        concrete_task_m.configuration_manager.add(conf_name, Hash.new, merge: true)
                    end
                end
                syskit_stub_deployment_model(task_m, deployment_name)
                model.to_instance_requirements.dup.
                    prefer_deployed_tasks(deployment_name)
            end

            # @api private
            #
            # Helper for {#syskit_stub_model}
            #
            # @param [InstanceRequirements] model
            def syskit_stub_composition_children(model, recursive: true, as: "")
                model = model.dup
                model.model.each_child do |child_name, child|
                    if child.composition_model? 
                        if recursive
                            model.use(child_name => syskit_stub(
                                child, recursive: true, as: "#{as}_#{child_name}"))
                        end
                    else
                        deployed_child = syskit_stub_task_context(child, "#{as}_#{child_name}")
                        model.use(child_name => deployed_child)
                    end
                end
                model
            end

            def self.syskit_stub_device(model, as: 'test', driver: nil)
                robot = Syskit::Robot::RobotDefinition.new

                driver ||= model.find_all_drivers.first
                if !driver
                    driver = Syskit::TaskContext.new_submodel do
                        driver_for model, as: 'driver'
                    end
                end
                robot.device(model, as: 'test', using: driver)
            end

            # Stubs the devices required by the given model
            def self.syskit_stub_required_devices(model)
                model = model.to_instance_requirements.dup
                model.model.each_master_driver_service do |srv|
                    if !model.arguments["#{srv.name}_dev"]
                        model.with_arguments("#{srv.name}_dev" => syskit_stub_device(srv.model, driver: model.model))
                    end
                end
                model
            end

            # Create a stub device of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<Device>] model the device model
            # @param [String] as the device name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def syskit_stub_device(model, as: 'test', driver: nil)
                self.class(model, as: 'test', driver: nil)
            end

            # Stubs the devices required by the given model
            def syskit_stub_required_devices(model)
                NetworkManipulation.syskit_stub_required_devices(model)
            end

            # Create an InstanceRequirement instance that would allow to deploy
            # the given model
            def syskit_stub(model, recursive: true, as: self.name, &block)
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                model = syskit_stub_required_devices(model)

                if model.composition_model? && recursive
                    syskit_stub_composition_children(
                        model, recursive: recursive, as: as)
                else
                    syskit_stub_task_context(model, as)
                end
            end

            def syskit_start_execution_agents(component, recursive: true)
                # Protect the component against configuration and startup
                plan.add_permanent(sync_ev = Roby::EventGenerator.new)
                component.should_configure_after(sync_ev)

                if component.kind_of?(Syskit::Composition) && recursive
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

            # Set this component instance up
            def syskit_configure(component, recursive: true)
                syskit_start_execution_agents(component, recursive: true)

                # Protect the component against startup and startup
                plan.add_permanent(sync_ev = Roby::EventGenerator.new)
                component.should_start_after(sync_ev)

                if component.kind_of?(Syskit::Composition) && recursive
                    component.each_child do |child_task|
                        if !child_task.setup?
                            syskit_configure(child_task, recursive: true)
                        end
                    end
                end

                component.freeze_delayed_arguments

                # Might already have been configured while waiting for the ready
                # event
                if !component.setup?
                    if !component.ready_for_setup?
                        component.ready_for_setup?
                    end

                    component.setup
                end
                component
            ensure
                if sync_ev
                    plan.remove_object(sync_ev)
                end
            end

            # Start this component
            def syskit_start(component, recursive: true)
                if !component.starting? && !component.running?
                    if !component.setup?
                        raise "#{component} is not set up, call #syskit_configure first"
                    end
                    component.start!
                end

                if !component.running?
                    assert_event_emission component.start_event
                end

                if recursive
                    component.each_child do |child|
                        if !child.running?
                            syskit_start(child, recursive: true)
                        end
                    end
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
            def syskit_stub_and_deploy(model = subject_syskit_model, recursive: true, as: self.name, &block)
                model = syskit_stub(model, recursive: recursive, as: as, &block)
                syskit_deploy(model, compute_policies: false)
            end

            def syskit_stub_deploy_and_configure(model = subject_syskit_model, recursive: true, as: self.name, &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
                syskit_configure(root, recursive: recursive)
                root
            end

            def syskit_stub_deploy_configure_and_start(model = subject_syskit_model, recursive: true, as: self.name, &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
                syskit_configure_and_start(root, recursive: recursive)
                root
            end

            def syskit_deploy_and_configure(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure(root, recursive: recursive)
            end

            def syskit_deploy_configure_and_start(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure_and_start(root, recursive: recursive)
            end

            def syskit_configure_and_start(component = subject_syskit_model, recursive: true)
                component = syskit_configure(component, recursive: recursive)
                syskit_start(component, recursive: recursive)
            end
        end
    end
end

