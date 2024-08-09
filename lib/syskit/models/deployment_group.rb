# frozen_string_literal: true

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
            #
            # @return [String=>ConfiguredDeployment]
            attr_reader :deployed_tasks

            # A mapping of a process server name to the underlying deployments
            # it provides
            #
            # @return [String=>Set<ConfiguredDeployment>]
            attr_reader :deployments

            DeployedTask = Struct.new :configured_deployment, :mapped_task_name do
                # Create an instance of this deployed task on the given plan
                #
                # @param [ConfiguredDeployment=>Syskit::Deployment] already
                #    instanciated deployment tasks, to be reused if self
                #    is part of the same ConfiguredDeployment
                def instanciate(plan, permanent: true, deployment_tasks: {})
                    deployment_task = (
                        deployment_tasks[[configured_deployment]] ||=
                            configured_deployment.new
                    )

                    if permanent
                        plan.add_permanent_task(deployment_task)
                    else
                        plan.add(deployment_task)
                    end
                    [deployment_task.task(mapped_task_name), deployment_task]
                end
            end

            def initialize
                @deployed_tasks = {}
                @deployments = {}
                invalidate_caches
            end

            def empty?
                deployments.all?(&:empty?)
            end

            def initialize_copy(original)
                super
                @deployed_tasks = {}
                @deployments = {}
                use_group!(original)
            end

            # Add all deployments in 'other' to self
            #
            # Unlike {#use_group!}, it will raise
            #
            # @param [#to_deployment_group] other the group that should be
            #   merged in self
            # @raise [TaskNameAlreadyInUse] if different deployments in 'other' and in
            #   'self' use the same task name. Use {#use_group!} if you want to
            #   override deployments in self instead.
            # @see use_group!
            def use_group(other)
                other = other.to_deployment_group
                @deployed_tasks =
                    @deployed_tasks
                    .merge(other.deployed_tasks) do |task_name, self_d, other_d|
                        if self_d != other_d
                            raise TaskNameAlreadyInUse.new(task_name, self_d, other_d),
                                  "there is already a deployment that "\
                                  "provides #{task_name}"
                        end
                        self_d
                    end
                other.deployments.each do |manager_name, manager_deployments|
                    (deployments[manager_name] ||= Set.new).merge(manager_deployments)
                end
                invalidate_caches
            end

            # Add all deployments in 'other' to self
            #
            # Unlike with {#use_group}, it will override tasks existing in self
            # by tasks from the argument that have the same name
            #
            # @param [#to_deployment_group] other the group that should be
            #   merged in self
            # @see use_group
            def use_group!(other)
                other = other.to_deployment_group
                @deployed_tasks.merge!(other.deployed_tasks) do |_, self_d, other_d|
                    if self_d != other_d
                        deployments[seld_d.process_server_name].delete(self_d)
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
                return unless (deployment = find_deployment_from_task_name(task_name))

                result = new
                result.register_deployed_task(task_name, deployment)
                result
            end

            # A mapping from task models to the set of registered
            # deployments that apply on these task models
            #
            # It is lazily computed when needed by
            # {#compute_task_context_deployment_candidates}
            #
            # @return [{Models::TaskContext=>Set<DeployedTask>}]
            #   mapping from task context models to a set of
            #   (machine_name,deployment_model,task_name) tuples representing
            #   the known ways this task context model could be deployed
            def task_context_deployment_candidates
                @task_context_deployment_candidates ||=
                    compute_task_context_deployment_candidates
            end

            # @api private
            #
            # Computes {#task_context_deployment_candidates}
            def compute_task_context_deployment_candidates
                deployed_models = {}
                deployments.each_value do |machine_deployments|
                    machine_deployments.each do |configured_deployment|
                        configured_deployment
                            .each_deployed_task_model do |mapped_task_name, task_model|
                                s = (deployed_models[task_model] ||= Set.new)
                                s << DeployedTask.new(
                                    configured_deployment, mapped_task_name
                                )
                            end
                    end
                end
                deployed_models
            end

            # Returns the set of deployments that are available for a given task
            #
            # @return [Set<DeployedTask>]
            def find_all_suitable_deployments_for(task)
                # task.model would be wrong here as task.model could be the
                # singleton class (if there are dynamic services)
                candidates = task_context_deployment_candidates[task.model]
                return candidates if candidates && !candidates.empty?

                candidates = task_context_deployment_candidates[task.concrete_model]
                return candidates if candidates && !candidates.empty?

                Syskit.debug do
                    "no deployments found for #{task} (#{task.concrete_model})"
                end
                Set.new
            end

            # Returns the deployment that provides the given task
            #
            # @return [ConfiguredDeployment,nil]
            def find_deployment_from_task_name(task_name)
                deployed_tasks[task_name]
            end

            # Returns all the deployments registered on a given process manager
            #
            # @return [Set<ConfiguredDeployment>]
            def find_all_deployments_from_process_manager(process_manager_name)
                deployments[process_manager_name] || Set.new
            end

            # Register a specific task of a configured deployment
            def register_deployed_task(task_name, configured_deployment)
                if (existing = find_deployment_from_task_name(task_name))
                    return if existing == configured_deployment

                    raise TaskNameAlreadyInUse.new(task_name, existing,
                                                   configured_deployment),
                          "there is already a deployment that provides #{task_name}"
                end

                deployed_tasks[tasks_name] = configured_deployment
                s = (deployments[configured_deployment.process_server_name] ||= Set.new)
                s << configured_deployment
                invalidate_caches
            end

            # Register a new deployment in this group
            def register_configured_deployment(configured_deployment)
                configured_deployment.each_orogen_deployed_task_context_model do |task|
                    orocos_name = task.name
                    existing = deployed_tasks[orocos_name]
                    if existing && existing != configured_deployment
                        raise TaskNameAlreadyInUse.new(orocos_name,
                                                       deployed_tasks[orocos_name],
                                                       configured_deployment),
                              "there is already a deployment that provides #{orocos_name}"
                    end
                end
                configured_deployment.each_orogen_deployed_task_context_model do |task|
                    deployed_tasks[task.name] = configured_deployment
                end
                s = (deployments[configured_deployment.process_server_name] ||= Set.new)
                s << configured_deployment
                invalidate_caches
            end

            # Enumerates all the deployments registered on self
            #
            # @yieldparam [ConfiguredDeployment]
            def each_configured_deployment
                return enum_for(__method__) unless block_given?

                deployments.each_value do |set|
                    set.each { |c| yield(c) }
                end
            end

            # Remove a deployment from this group
            def deregister_configured_deployment(configured_deployment)
                deployments[configured_deployment.process_server_name]
                    .delete(configured_deployment)
                configured_deployment.each_orogen_deployed_task_context_model do |task|
                    deployed_tasks.delete(task.name)
                end
            end

            # @api private
            #
            # Invalidate cached values computed based on the deployments
            # available in this group
            def invalidate_caches
                @task_context_deployment_candidates = nil
            end

            # Deploy {RubyTaskContext} models
            #
            # @param [Boolean] remote_task when running the task, tell the
            #   process manager to set it up as if it was a remote task,
            #   instead of an in-process ruby task. This is used for testing,
            #   to check for instance that Syskit code does not access blocking
            #   network calls in the main thread
            # @param [String] on the name of the process manager that should
            #   be used
            # @param process_managers the object that maintains the set of
            #   process managers
            # @param [Boolean|#===|Array<#===>] read_only set the deployment or some of
            # the deployed tasks as read only. To set the whole deployment as read only,
            # one should pass read_only: true. To set some tasks, pass a regex that
            # matches the deployed task names. Defaults to false.
            # @return [[ConfiguredDeployment]]
            def use_ruby_tasks(
                mappings, remote_task: false, on: "ruby_tasks",
                process_managers: Syskit.conf, read_only: false
            )
                # Verify that the process manager exists
                process_managers.process_server_config_for(on)

                if !mappings.respond_to?(:each_key)
                    raise ArgumentError, "mappings should be given as model => name"
                elsif mappings.size > 1
                    Roby.warn_deprecated(
                        "defining more than one ruby task context " \
                        "deployment in a single use_ruby_tasks call is deprecated"
                    )
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
                    configured_deployment =
                        Models::ConfiguredDeployment
                        .new(on, deployment_model, { "task" => name }, name,
                             { task_context_class: task_context_class },
                             read_only: read_only)
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # Deploy oroGen-generated tasks within the Syskit process itself
            #
            # Valid values for the `activity` parameter:
            # * type: "periodic", period: PERIOD_IN_SECONDS
            # * type: "triggered"
            # * type: "slave"
            # * type: "fd_driven"
            #
            # @param [Hash] model_to_name mapping of an syskit task context model to
            #   the desired task name, e.g. `OroGen.orogen_syskit_tests.Task => "task"`
            # @param [Hash] activity specification of an activity if the task's default
            #   activity needs to be overriden.
            # @param [String] on the name of the process manager that should
            #   be used
            # @param process_managers the object that maintains the set of
            #   process managers
            # @param [Boolean|#===|Array<#===>] read_only set the deployment or some of
            #   the deployed tasks as read only. To set the whole deployment as read only,
            #   one should pass read_only: true. To set some tasks, pass a regex that
            #   matches the deployed task names. Defaults to false.
            # @return [[ConfiguredDeployment]]
            def use_in_process_tasks(
                model_to_name = {}, on: "in_process_tasks",
                activity: {}, read_only: false, **model_to_name_kw
            )
                unless model_to_name.respond_to?(:each_key)
                    raise ArgumentError, "mappings should be given as model => name"
                end

                model_to_name = model_to_name.merge(model_to_name_kw)
                model_to_name.each do |task_model, _name|
                    validate_task_model_is_plain(task_model)
                end

                model_to_name.map do |task_model, name|
                    task_name, deployment_m = in_process_tasks_create_deployment_model(
                        task_model, activity
                    )

                    configured_deployment =
                        Models::ConfiguredDeployment
                        .new(on, deployment_m, { task_name => name }, name,
                             read_only: read_only)
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # @api private
            #
            # oroGen spec for a task model's default deployment
            #
            # @param [Class<Syskit::TaskContext>] task_model the task model of interest
            # @param [OroGen::Loaders::Base] loader the orogen loader used to resolve
            #   the model
            # @return [OroGen::Spec::TaskDeployment] the task model's default deployment
            def in_process_tasks_create_deployment_model(
                task_model, activity
            )
                default_deployment_name =
                    OroGen::Spec::Project
                    .default_deployment_name(task_model.orogen_model.name)

                deployed_task = nil
                syskit_deployment_m = Syskit::Deployment.new_submodel do
                    deployed_task = task(default_deployment_name, task_model)
                end
                in_process_tasks_override_activity(deployed_task, activity)
                [default_deployment_name, syskit_deployment_m]
            end

            # @api private
            #
            # Update a deployed task's activity based on {#use_in_process_tasks}'
            # activity parameter
            #
            # @param [OroGen::Spec::TaskDeployment] deployed_task_model the orogen
            #   specification for the deployed task
            # @param [Hash] activity
            def in_process_tasks_override_activity(deployed_task_model, activity)
                return if activity.empty?

                case activity[:type].to_sym
                when :periodic
                    deployed_task_model.periodic(activity.fetch(:period))
                when :triggered
                    deployed_task_model.triggered
                when :fd_driven
                    deployed_task_model.fd_driven
                when :slave
                    deployed_task_model.slave
                else
                    raise ArgumentError, "invalid activity type #{activity}"
                end
            end

            # Declare tasks that are going to be started by some other process,
            # but whose tasks are going to be integrated in the syskit network
            #
            # @param [Boolean|#===|Array<#===>] read_only set the deployment or some of
            # the deployed tasks as read only. To set the whole deployment as read only,
            # one should pass read_only: true. To set some tasks, pass a regex that
            # matches the deployed task names. Defaults to false.
            def use_unmanaged_task(mappings,
                on: "unmanaged_tasks", process_managers: Syskit.conf, read_only: false)
                # Verify that the process manager exists
                process_managers.process_server_config_for(on)

                model_to_name = mappings.map do |task_model, name|
                    if task_model.respond_to?(:to_str)
                        Roby.warn_deprecated(
                            "specifying the task model as string "\
                            "is deprecated. Load the task library and use Syskit's "\
                            "task class"
                        )
                        task_model_name = task_model
                        task_model = Syskit::TaskContext
                                     .find_model_from_orogen_name(task_model_name)
                        unless task_model
                            raise ArgumentError,
                                  "#{task_model_name} is not a known oroGen model name"
                        end
                    end
                    [task_model, name]
                end

                model_to_name.each do |task_model, _name|
                    validate_task_model_is_plain(task_model)
                end

                model_to_name.map do |task_model, name|
                    orogen_model = task_model.orogen_model
                    deployment_model =
                        Syskit::Deployment
                        .new_submodel(name: "Deployment::Unmanaged::#{name}") do
                            task name, orogen_model
                        end

                    configured_deployment =
                        Models::ConfiguredDeployment
                        .new(on, deployment_model, { name => name }, name, {},
                             read_only: read_only)
                    register_configured_deployment(configured_deployment)
                    configured_deployment
                end
            end

            # Raise if a given task model is not a "plain" orogen-generated task context
            def validate_task_model_is_plain(task_m)
                return if plain_task_context_model?(task_m)

                raise ArgumentError,
                      "expected a mapping from a task context "\
                      "model to a name, but got #{task_m}"
            end

            # Tests whether a given task model is a "plain" orogen-generated task context
            def plain_task_context_model?(model)
                model.kind_of?(Class) &&
                    (model <= Syskit::TaskContext) &&
                    !(model <= Syskit::RubyTaskContext)
            end

            def deployment_model?(model)
                model.kind_of?(Class) && model <= Syskit::Deployment
            end

            # @api private
            #
            # Helper to {#use_deployment} and {#use_deployments_from} to resolve
            # the process server config as well as the orogen loader object
            # based on its arguments
            def resolve_process_config_and_loader_from_use_arguments(
                on, simulation, loader, process_managers
            )
                process_server_name = on
                process_server_config =
                    if simulation
                        process_managers
                            .sim_process_server_config_for(process_server_name)
                    else
                        process_managers
                            .process_server_config_for(process_server_name)
                    end

                loader ||= process_server_config.loader

                [process_server_config, loader]
            end

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            # @param [Boolean|#===] read_only set the deployment or some of the deployed
            #   tasks as read only. To set the whole deployment as read only, one should
            #   pass read_only: true. To set some tasks, pass a regex that matches the
            #   deployed task names. Defaults to false.
            #
            # @return [Array<Deployment>]
            def use_deployment(
                *names,
                on: "localhost",
                simulation: Roby.app.simulation?,
                loader: nil,
                process_managers: Syskit.conf,
                read_only: false,
                logger_name: nil,
                execution_mode: nil,
                **run_options
            )
                deployment_spec = {}
                deployment_spec = names.pop if names.last.kind_of?(Hash)

                process_server_config, loader =
                    resolve_process_config_and_loader_from_use_arguments(
                        on, simulation, loader, process_managers
                    )

                ## WORKAROUND FOR 2.7.0
                Roby.sanitize_keywords_to_hash(deployment_spec, run_options)

                deployments_by_name = {}
                names = names.map do |n|
                    if n.respond_to?(:orogen_model)
                        if !n.kind_of?(Class)
                            raise ArgumentError,
                                  "only deployment models can be given without a name"
                        elsif n <= Syskit::TaskContext && !(n <= Syskit::RubyTaskContext)
                            raise TaskNameRequired,
                                  "you must provide a task name when starting a "\
                                  "component by type, as e.g. use_deployment "\
                                  "OroGen.xsens_imu.Task => 'imu'"
                        elsif !(n <= Syskit::Deployment)
                            raise ArgumentError,
                                  "only deployment models can be given without a name"
                        end
                        deployments_by_name[n.orogen_model.name] = n
                        n.orogen_model
                    else n
                    end
                end
                deployment_spec = deployment_spec.transform_keys do |k|
                    if k.respond_to?(:to_str)
                        k
                    else
                        unless plain_task_context_model?(k) || deployment_model?(k)
                            raise ArgumentError,
                                  "only deployment and task context "\
                                  "models can be deployed by use_deployment, got #{k}"
                        end
                        deployments_by_name[k.orogen_model.name] = k
                        k.orogen_model
                    end
                end

                new_deployments, = Orocos::Process.parse_run_options(
                    *names, deployment_spec, loader: loader, **run_options
                )
                new_deployments.map do |deployment_name, name_mappings, name, spawn_options|
                    # Workaround until we get rid of parse_run_options
                    #
                    # In Syskit's case, both log dir and working directory are controlled
                    # by the process server config
                    spawn_options.delete(:working_directory)
                    spawn_options.delete(:wait)
                    spawn_options[:execution_mode] = execution_mode if execution_mode
                    unless (model = deployments_by_name[deployment_name])
                        orogen_model = loader.deployment_model_from_name(deployment_name)
                        model = Syskit::Deployment.find_model_by_orogen(orogen_model)
                    end
                    model.default_run_options.merge!(
                        process_managers.default_run_options(model)
                    )

                    configured_deployment =
                        Models::ConfiguredDeployment
                        .new(process_server_config.name, model, name_mappings, name,
                             spawn_options, read_only: read_only, logger_name: logger_name)
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
            def use_deployments_from(
                project_name,
                on: "localhost",
                simulation: Roby.app.simulation?,
                loader: nil,
                process_managers: Syskit.conf,
                **use_options
            )
                Syskit.info "using deployments from #{project_name}"
                _, loader = resolve_process_config_and_loader_from_use_arguments(
                    on, simulation, loader, process_managers
                )
                orogen = loader.project_model_from_name(project_name)

                result = []
                orogen.each_deployment do |deployment_def|
                    if deployment_def.install?
                        Syskit.info "  #{deployment_def.name}"
                        result << use_deployment(
                            deployment_def.name,
                            on: on,
                            simulation: simulation,
                            loader: loader,
                            process_managers: process_managers,
                            **use_options
                        )
                    end
                end
                result
            end

            # Method expected by {#use_group} and {#use_group!} to normalize an
            # object to a DeploymentGroup object
            #
            # Define this method on objects that can be used as deployment
            # groups to make their usage transparent
            #
            # This returns self
            def to_deployment_group
                self
            end

            def pretty_print(pp)
                pp.text "Deployment group with #{deployed_tasks.size} deployed tasks"
                pp.breakable
                pp.text "By task:"
                pp.nest(2) do
                    deployed_tasks.each do |name, task|
                        pp.breakable
                        pp.text "#{name}: "
                        task.pretty_print(pp)
                    end
                end
                pp.breakable
                pp.text "By model:"
                pp.nest(2) do
                    task_context_deployment_candidates.each do |model, candidates|
                        pp.breakable
                        pp.text "#{model}: #{candidates.size} candidates"
                        pp.nest(2) do
                            candidates.each do |c|
                                pp.breakable
                                c.pretty_print(pp)
                            end
                        end
                    end
                end
            end
        end
    end
end
