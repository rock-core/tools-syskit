module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def stub_syskit_task_context_model(name, &block)
                TaskContext.new_submodel(:name => name, &block)
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
            def stub_syskit_deployment_model(task_model = nil, name = nil, &block)
                if task_model
                    task_model = task_model.to_component_model
                    name ||= task_model.name
                end
                deployment_model = Deployment.new_submodel(:name => name) do
                    if task_model
                        task(name, task_model.orogen_model)
                    end
                    if block_given?
                        instance_eval(&block)
                    end
                end

                Syskit.conf.process_server_for('stubs').
                    register_deployment_model(deployment_model.orogen_model)
                Syskit.conf.use_deployment(deployment_model.orogen_model, :on => 'stubs')
                deployment_model
            end

            # Create a new stub deployment instance
            def stub_syskit_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= stub_syskit_deployment_model(nil, name, &block)
                plan.add_permanent(task = deployment_model.new(:process_name => name, :on => 'stubs'))
                task
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
            def stub_and_deploy_composition(model, options = Hash.new)
                model = model.to_instance_requirements.dup
                options = Kernel.validate_options options, :recursive => false,
                    :prefix => ""

                model.model.each_child do |child_name, child|
                    if child.composition_model? 
                        if options[:recursive]
                            model.use(child_name => stub_and_deploy_composition(child, :prefix => "#{options[:prefix]}_#{child_name}"))
                        end
                        next
                    end

                    task_m = child.model
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
                    end
                    stub_syskit_deployment_model(task_m, "#{options[:prefix]}_#{child_name}")
                    model.use(child_name => task_m).prefer_deployed_tasks(child_name)
                end
                syskit_run_deployer(model, :compute_policies => false)
            end

            def stub_deploy_and_start_composition(model, options = Hash.new)
                root = stub_and_deploy_composition(model, options)
                syskit_start_component(root)
            end

            def stub_deploy_and_configure_composition(model, options = Hash.new)
                root = stub_and_deploy_composition(model, options)
                syskit_setup_component(root)
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
                deployment_m = stub_syskit_deployment_model(task_model, orocos_name)
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
                end
                component.arguments[:conf] ||= []
                component.setup
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
                stub_syskit_deployment_model(*args, &block)
            end

        end
    end
end

