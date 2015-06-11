module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            def setup
                @__test_created_deployments = Array.new
                super
            end

            def teardown
                super
                @__test_created_deployments.each do |d|
                    Syskit.conf.deregister_configured_deployment(d)
                end
            end

            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def stub_syskit_task_context_model(name, &block)
                model = TaskContext.new_submodel(:name => name, &block)
                model.orogen_model.extended_state_support
                model
            end

            # Create a new stub task context instance and add it to the plan
            #
            # @param [String] name the orocos_name of the new task
            # @param [Model<Syskit::TaskContext>,String,nil] task_model the task
            #   model. If a string or nil, a new task context model will be
            #   created using task_model as a name (or no name if nil). In this
            #   case, the given block is used to define the task context
            #   interface
            # @return [Syskit::TaskContext] the new task instance. It is already
            #   added to #plan
            def stub_syskit_task_context(name = "task", task_model = nil, &block)
                if !task_model || task_model.respond_to?(:to_str)
                    task_model = stub_syskit_task_context_model(task_model, &block)
                end
                plan.add_permanent(task = task_model.new(:orocos_name => name))
                task
            end

            def stub_syskit_deployment_model(task_model = nil, name = nil, &block)
                stub_deployment_model(task_model, name, &block)
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
            def stub_deployment_model(task_model = nil, name = nil, &block)
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

            # Create a new stub deployment instance
            def stub_syskit_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= stub_deployment_model(nil, name, &block)
                plan.add_permanent(task = deployment_model.new(:process_name => name, :on => 'stubs'))
                task
            end

            # @api private
            #
            # Helper for {#stub_and_deploy}
            #
            # @param [InstanceRequirements] task_m the task context model
            # @param [String] deployment_name the deployment name
            def stub_and_deploy_task_context(model, deployment_name)
                model = model.dup
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
                        task_m.provides srv, :as => "srv#{idx}"
                    end
                elsif task_m.abstract?
                    task_m = task_m.new_submodel
                    model.add_models(task_m)
                end
                stub_deployment_model(task_m, name)
                model.prefer_deployed_tasks(name)
            end

            # @api private
            #
            # Helper for {#stub_and_deploy}
            #
            # @param [InstanceRequirements] model
            def stub_and_deploy_composition_children(model, recursive: false, prefix: "")
                model = model.dup
                model.model.each_child do |child_name, child|
                    if child.composition_model? 
                        if recursive
                            model.use(child_name => stub_and_deploy(child, prefix: "#{prefix}_#{child_name}"))
                        end
                    else
                        deployed_child = stub_and_deploy_task_context(child, "#{prefix}_#{child_name}")
                        model.use(child_name => deployed_child)
                    end
                end
                model
            end

            # Deploy the given composition, replacing every single data service
            # and task context by a ruby task context, allowing to then test.
            #
            # The resulting composition gets started (recursively)
            #
            # @option options [Boolean] :recursive (false) if true, the
            #   method will stub the children of compositions that are used by
            #   the root composition. Otherwise, you have to refer to them in
            #   the original instance requirements
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
            #   stub_deploy_and_start_composition(model)
            def stub_and_deploy(model, recursive: false, as: nil, prefix: nil, &block)
                if model.respond_to?(:to_str)
                    model = stub_syskit_task_context_model(model, &block)
                end
                model = model.to_instance_requirements.dup

                if prefix
                    Syskit.warn "the 'prefix' option to stub_and_deploy is deprecated, use 'as' instead"
                    as = prefix
                end

                if model.composition_model?
                    model = stub_and_deploy_composition_children(model, recursive: recursive, prefix: (as || ""))
                else
                    model = stub_and_deploy_task_context(model, as || "task")
                end

                syskit_run_deployer(model, compute_policies: false)
            end

            def stub_deploy_and_start(model, options = Hash.new, &block)
                root = stub_and_deploy(model, options, &block)
                syskit_start_component(root)
            end

            def stub_deploy_and_configure(model, options = Hash.new, &block)
                root = stub_and_deploy(model, options, &block)
                syskit_setup_component(root)
            end

            def use_deployment(*args)
                @__test_created_deployments.concat(Syskit.conf.use_deployment(*args).to_a)
            end

            def use_ruby_tasks(*args)
                @__test_created_deployments.concat(Syskit.conf.use_ruby_tasks(*args).to_a)
            end

            def deploy(model, options = Hash.new)
                syskit_run_deployer(model, compute_policies: true)
            end

            def deploy_and_configure(model, options = Hash.new)
                root = deploy(model, options)
                syskit_setup_component(root)
            end

            def stub_and_deploy_composition(*args, **kw_args)
                Syskit.warn "#stub_and_deploy_composition is deprecated in favor of #stub_and_deploy"
                stub_and_deploy(*args, **kw_args)
            end

            def stub_deploy_and_start_composition(*args, **kw_args)
                Syskit.warn "#stub_deploy_and_start_composition is deprecated in favor of #stub_deploy_and_start"
                stub_deploy_and_start(*args, **kw_args)
            end

            def stub_deploy_and_configure_composition(*args, **kw_args)
                Syskit.warn "#stub_deploy_and_configure_composition is deprecated in favor of #stub_deploy_and_configure"
                stub_deploy_and_configure(*args, **kw_args)
            end

            # Create a new deployed instance of a task context model
            #
            # @param [Model<Syskit::TaskContext>,String] task_model the task
            #   context model. If it is a string, it is the name fo a task
            #   context model that is created using a block given to the method
            # @param [String] the name of the deployed task
            #
            # @overload syskit_deploy_task_context(task_m, 'stub_task')
            # @overload syskit_deploy_task_context('Task', 'stub_task') { # output_port ... }
            def syskit_deploy_task_context(task_model, orocos_name = 'task')
                if task_model.respond_to?(:to_str)
                    task_model = stub_syskit_task_context_model(task_model, &proc)
                end
                deployment_m = stub_deployment_model(task_model, orocos_name)
                plan.add(deployment = deployment_m.new(:on => 'stubs'))
                task = deployment.task orocos_name
                plan.add_permanent(task)
                deployment.start!
                task
            end

            # Create a new deployed instance of a task context model and start
            # it
            def syskit_deploy_and_start_task_context(task_model, name = 'task')
                task = syskit_deploy_task_context(task_model, name)
                syskit_start_component(task)
                task
            end

            # Set this component instance up
            def syskit_setup_component(component)
                if component.abstract?
                    component = syskit_run_deployer(component)
                end

                if component.kind_of?(Syskit::Composition)
                    component.each_child do |child_task|
                        if !child_task.setup?
                            syskit_setup_component(child_task)
                        end
                    end
                end

                if agent = component.execution_agent
                    if !agent.running?
                        agent.start!
                    end
                    if !agent.ready?
                        assert_event_emission agent.ready_event
                    end
                end

                component.freeze_delayed_arguments

                # Might already have been configured while waiting for the ready
                # event
                if !component.setup?
                    component.setup
                end
                component
            end

            # Start this component
            #
            # If needed, it sets it up first
            def syskit_start_component(component)
                if component.abstract?
                    component = syskit_run_deployer(component)
                end

                if component.kind_of?(Syskit::Composition)
                    component.each_child do |child_task|
                        if !child_task.setup?
                            syskit_setup_component(child_task)
                        end
                    end
                end
                if !component.setup?
                    syskit_setup_component(component)
                end
                if !component.running? && !component.starting?
                    assert_event_emission component.start_event do
                        component.start!
                    end
                end
                syskit_start_task_recursively(component)
                component
            end

            def syskit_start_task_recursively(root)
                if !root.running?
                    assert_event_emission root.start_event
                end

                root.each_child do |child|
                    if !child.running?
                        assert_event_emission child.start_event
                    end
                end
            end

            # @deprecated
            def start_task_context(task)
                syskit_start_component(task)
            end

            # @deprecated
            def stub_roby_task_context(name = "task", task_model = nil, &block)
                stub_syskit_task_context(name, task_model, &block)
            end

            # @deprecated
            def stub_roby_deployment_model(*args, &block)
                stub_deployment_model(*args, &block)
            end

        end
    end
end

