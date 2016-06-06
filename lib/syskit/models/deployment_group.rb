module Syskit
    module Models
        # A set of deployments logically grouped together
        #
        # This is the underlying data structure used by {Profile} and
        # {InstanceRequirements} to manage the deployments. It also provides the
        # API to resolve a task's deployment
        class DeploymentGroup
            # Mapping of a deployed task name to the underlying configured
            # deployment that provides it
            attr_reader :deployed_tasks

            # A mapping of a process server name to the underlying deployments
            # it provides
            attr_reader :deployments

            def initialize
                @deployed_tasks = Hash.new
                @deployments = Hash.new
                invalidate_caches
            end

            def empty?
                deployments.all?(&:empty?)
            end

            def initialize_copy(original)
                super
                @deployed_tasks = Hash.new
                @deployments = Hash.new
                use_group!(original)
            end

            # Add all deployments in 'other' to self
            def use_group(other)
                @deployed_tasks = @deployed_tasks.merge(other.deployed_tasks) do |task_name, self_deployment, other_deployment|
                    if self_deployment != other_deployment
                        raise TaskNameAlreadyInUse.new(
                            task_name,
                            self_deployment,
                            other_deployment), "there is already a deployment that provides #{task_name}"
                    end
                    self_deployment
                end
                other.deployments.each do |manager_name, manager_deployments|
                    (deployments[manager_name] ||= Set.new).merge(manager_deployments)
                end
                invalidate_caches
            end

            # Add all deployments in 'other' to self
            def use_group!(other)
                @deployed_tasks.merge!(other.deployed_tasks) do |task_name, self_deployment, other_deployment|
                    if self_deployment != other_deployment
                        deployments[self_deployment.process_server_name].delete(self_deployment)
                    end
                    other_deployment
                end
                other.deployments.each do |manager_name, manager_deployments|
                    (deployments[manager_name] ||= Set.new).merge(manager_deployments)
                end
                invalidate_caches
            end

            def has_deployed_task?(task_name)
                find_deployment_from_task_name(task_name)
            end

            # Returns a deployment group that represents a single deployed task
            def find_deployed_task_by_name(task_name)
                if configured_deployment = find_deployment_from_task_name(task_name)
                    result = new
                    result.register_deployed_task(task_name, configured_deployment)
                    result
                end
            end

            # A mapping from task models to the set of registered
            # deployments that apply on these task models
            #
            # It is lazily computed when needed by
            # {#compute_task_context_deployment_candidates}
            #
            # @return [{Models::TaskContext=>Set<(Models::Deployment,String)>}]
            #   mapping from task context models to a set of
            #   (machine_name,deployment_model,task_name) tuples representing
            #   the known ways this task context model could be deployed
            def task_context_deployment_candidates
                @task_context_deployment_candidates ||= compute_task_context_deployment_candidates
            end

            # @api private
            #
            # Computes {#task_context_deployment_candidates}
            def compute_task_context_deployment_candidates
                deployed_models = Hash.new
                deployments.each do |machine_name, machine_deployments|
                    machine_deployments.each do |configured_deployment|
                        configured_deployment.each_deployed_task_model do |task_name, task_model|
                            deployed_models[task_model] ||= Set.new
                            deployed_models[task_model] << [configured_deployment, task_name]
                        end
                    end
                end
                deployed_models
            end

            # Returns the set of deployments that are available for a given task
            #
            # @return [Set<ConfiguredDeployment>]
            def find_all_suitable_deployments_for(task)
                # task.model would be wrong here as task.model could be the
                # singleton class (if there are dynamic services)
                candidates = task_context_deployment_candidates[task.model]
                if !candidates || candidates.empty?
                    candidates = task_context_deployment_candidates[task.concrete_model]
                    if !candidates || candidates.empty?
                        Syskit.debug { "no deployments found for #{task} (#{task.concrete_model})" }
                        return Set.new
                    end
                end
                return candidates
            end

            # Returns the deployment that provides the given task
            #
            # @return [ConfiguredDeployment,nil]
            def find_deployment_from_task_name(task_name)
                deployed_tasks[task_name]
            end

            # Returns all the deployments registered on a given process manager
            def find_all_deployments_from_process_manager(process_manager_name)
                deployments[process_manager_name] || Array.new
            end

            # Register a specific task of a configured deployment
            def register_deployed_task(task_name, configured_deployment)
                if existing = find_deployment_from_task_name(task_name)
                    if existing != configured_deployment
                        raise TaskNameAlreadyInUse.new(task_name, existing, configured_deployment), "there is already a deployment that provides #{task_name}"
                    end
                    return
                end

                deployed_tasks[tasks_name] = configured_deployment
                deployments[configured_deployment.process_server_name] ||= Set.new
                deployments[configured_deployment.process_server_name] << configured_deployment
            end

            # Register a new deployment in this group
            def register_configured_deployment(configured_deployment)
                configured_deployment.each_orogen_deployed_task_context_model do |task|
                    orocos_name = task.name
                    if deployed_tasks[orocos_name] && deployed_tasks[orocos_name] != configured_deployment
                        raise TaskNameAlreadyInUse.new(orocos_name, deployed_tasks[orocos_name], configured_deployment), "there is already a deployment that provides #{orocos_name}"
                    end
                end
                configured_deployment.each_orogen_deployed_task_context_model do |task|
                    deployed_tasks[task.name] = configured_deployment
                end
                deployments[configured_deployment.process_server_name] ||= Set.new
                deployments[configured_deployment.process_server_name] << configured_deployment
                invalidate_caches
            end

            # @api private
            #
            # Invalidate cached values computed based on the deployments
            # available in this group
            def invalidate_caches
                @task_context_deployment_candidates = nil
            end

            # Declare deployed versions of some Ruby tasks
            def use_ruby_tasks(mappings, remote_task: false, on: 'ruby_tasks', process_managers: Syskit.conf)
                # Verify that the process manager exists
                process_managers.process_server_config_for(on)

                if !mappings.respond_to?(:each_key)
                    raise ArgumentError, "mappings should be given as model => name"
                elsif mappings.size > 1
                    Roby.warn_deprecated "defining more than one ruby task context " \
                        "deployment in a single use_ruby_tasks call is deprecated"
                end

                mappings.each_key do |task_model|
                    valid_model = task_model.kind_of?(Class) &&
                        (task_model <= Syskit::RubyTaskContext)
                    unless valid_model
                        raise ArgumentError, "#{task_model} is not a ruby task model"
                    end
                end

                task_context_class =
                    if remote_task
                        Orocos::RubyTasks::RemoteTaskContext
                    else
                        Orocos::RubyTasks::TaskContext
                    end

                mappings.map do |task_model, name|
                    deployment_model = task_model.deployment_model
                    configured_deployment = Models::ConfiguredDeployment.
                        new(on, deployment_model, Hash['task' => name], name,
                            Hash[task_context_class: task_context_class])
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # Declare tasks that are going to be started by some other process,
            # but whose tasks are going to be integrated in the syskit network
            def use_unmanaged_task(mappings, on: 'unmanaged_tasks', process_managers: Syskit.conf)
                # Verify that the process manager exists
                process_managers.process_server_config_for(on)

                model_to_name = mappings.map do |task_model, name|
                    if task_model.respond_to?(:to_str)
                        task_model_name = task_model
                        task_model = Syskit::TaskContext.find_model_from_orogen_name(task_model_name)
                        if !task_model
                            raise ArgumentError, "#{task_model_name} is not a known oroGen model name"
                        end
                    end
                    [task_model, name]
                end

                model_to_name.each do |task_model, _name|
                    is_pure_task_context_model =
                        task_model.kind_of?(Class) &&
                        (task_model <= Syskit::TaskContext) &&
                        !(task_model <= Syskit::RubyTaskContext)
                    raise ArgumentError, "expected a mapping from a task context "\
                        "model to a name, but got #{task_model}" \
                        unless is_pure_task_context_model
                end

                model_to_name.map do |task_model, name|
                    orogen_model = task_model.orogen_model
                    deployment_model = Deployment.new_submodel(name: "Deployment::Unmanaged::#{name}") do
                        task name, orogen_model
                    end

                    configured_deployment = Models::ConfiguredDeployment.
                        new(on, deployment_model, Hash[name => name], name, Hash.new)
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            #
            # @return [Array<Deployment>]
            def use_deployment(*names, on: 'localhost', simulation: Roby.app.simulation?, loader: Roby.app.default_loader, process_managers: Syskit.conf, **run_options)
                deployment_spec = Hash.new
                if names.last.kind_of?(Hash)
                    deployment_spec = names.pop
                end

                process_server_name = on
                process_server_config =
                    if simulation
                        process_managers.sim_process_server_config_for(process_server_name)
                    else
                        process_managers.process_server_config_for(process_server_name)
                    end

                deployments_by_name = Hash.new
                names = names.map do |n|
                    if n.respond_to?(:orogen_model)
                        if !n.kind_of?(Class)
                            raise ArgumentError, "only deployment models can be given "\
                                "without a name"
                        elsif n <= Syskit::TaskContext && !(n <= Syskit::RubyTaskContext)
                            raise TaskNameRequired, "you must provide a task name when starting a "\
                                "component by type, as e.g. use_deployment "\
                                "OroGen.xsens_imu.Task => 'imu'"
                        elsif !(n <= Syskit::Deployment)
                            raise ArgumentError, "only deployment models can be given "\
                                "without a name"
                        end
                        deployments_by_name[n.orogen_model.name] = n
                        n.orogen_model
                    else n
                    end
                end
                deployment_spec = deployment_spec.map_key do |k|
                    if k.respond_to?(:to_str)
                        k
                    else
                        is_valid =
                            k.kind_of?(Class) &&
                            (k <= Syskit::TaskContext || k <= Syskit::Deployment) &&
                            !(k <= Syskit::RubyTaskContext)
                        unless is_valid
                            raise ArgumentError, "only deployment and task context "\
                                "models can be deployed by use_deployment, got #{k}"
                        end
                        deployments_by_name[k.orogen_model.name] = k
                        k.orogen_model
                    end
                end

                new_deployments, _ = Orocos::Process.parse_run_options(
                    *names, deployment_spec, loader: loader, **run_options)
                new_deployments.map do |deployment_name, mappings, name, spawn_options|
                    if !(model = deployments_by_name[deployment_name])
                        orogen_model = loader.deployment_model_from_name(deployment_name)
                        model = Syskit::Deployment.find_model_by_orogen(orogen_model)
                    end
                    model.default_run_options.merge!(process_managers.default_run_options(model))

                    configured_deployment = Models::ConfiguredDeployment.
                        new(process_server_config.name, model, mappings, name, spawn_options)
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # Add all the deployments defined in the given oroGen project to the
            # set of deployments that the engine can use.
            #
            # @option options [String] :on the name of the process server this
            #   project should be loaded from
            # @return [Array<Model<Deployment>>] the set of deployments
            # @see #use_deployment
            def use_deployments_from(project_name, process_managers: Syskit.conf, loader: Roby.app.default_loader, **use_options)
                Syskit.info "using deployments from #{project_name}"
                orogen = loader.project_model_from_name(project_name)

                result = []
                orogen.each_deployment do |deployment_def|
                    if deployment_def.install?
                        Syskit.info "  #{deployment_def.name}"
                        result << use_deployment(deployment_def.name, process_managers: process_managers, loader: loader, **use_options)
                    end
                end
                result
            end
        end
    end
end
