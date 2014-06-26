require 'orocos/ruby_process_server'
module Syskit
    module RobyApp
        # Syskit engine configuration interface
        #
        # The main configuration instance is accessible as Syskit.conf or (if
        # running in a Roby application) as Conf.syskit
        class Configuration < Roby::OpenStruct
            # The application that we are configuring
            # @return [Roby::Application]
            attr_reader :app
            # If true, we will load the component-specific code in
            # tasks/orocos/. It is true by default
            attr_predicate :load_component_extensions, true
            # If true, files that raise an error during task library or type
            # import will be ignored. This is usually used on "root" bundles
            # (e.g. the Rock bundle) to have the benefit of GUIs like
            # system_model even though some typekits/task libraries are not
            # present
            attr_predicate :ignore_missing_orogen_projects_during_load, true
            # If true, files that raise an error will be ignored. This is
            # usually used on "root" bundles (e.g. the Rock bundle) to have the
            # benefit of GUIs like browse even though some files have
            # errors
            attr_predicate :ignore_load_errors, true
            # The set of process servers registered so far
            # @return [Hash<String,ProcessServerConfig>]
            attr_reader :process_servers
            # Controls whether models from the installed components should be
            # used or not
            attr_predicate :use_only_model_pack?, true

            def initialize(app)
                super()

                @app = app
                @process_servers = Hash.new
                @load_component_extensions = true
                @log_enabled = true
                @conf_log_enabled = true
                @redirect_local_process_server = true
                @default_logging_buffer_size = 25
                @reject_ambiguous_deployments = true
                @auto_configure = true
                @only_load_models = false
                @disables_local_process_server = false
                @start_all_deployments = false
                @local_only = false
                @prefix_blacklist = []
                @sd_publish_list = []
                @ignore_missing_orogen_projects_during_load = false
                @ignore_load_errors = false
                @buffer_size_margin = 0.1
                @use_only_model_pack = false

                @log_groups = { nil => LogGroup.new(false) }

                registry = Typelib::Registry.new
                Typelib::Registry.add_standard_cxx_types(registry)
                registry.each do |t|
                    if t < Typelib::NumericType
                        main_group.names << t.name
                    end
                end
            end

            def create_subfield(name)
                Roby::OpenStruct.new(model, self, name)
            end

            # Resets this Syskit configuration object
            #
            # Note that it is called by {#initialize}
            def clear
                super
                @deployments = Hash.new { |h, k| h[k] = Set.new }
                @deployed_tasks = Hash.new
            end

            # The default buffer size that should be used when setting up a
            # logger connection
            #
            # Defaults to 25
            #
            # @return [Integer]
            attr_accessor :default_logging_buffer_size

            # The set of currently defined log groups
            #
            # It is a mapping from the log group name to the corresponding
            # LogGroup instance
            attr_reader :log_groups

            # The main log filter
            #
            # See #log_group
            def main_group
                log_groups[nil]
            end

            # Create a new log group with the given name
            #
            # A log groups are sets of filters that are used to match
            # deployments, tasks or specific ports. These filters can be enabled
            # or disabled using their name with #enable_log_group and
            # #disable_log_group
            def log_group(name, &block)
                group = LogGroup.new
                group.load(&block)
                log_groups[name.to_str] = group
            end

            # Exclude +object+ from the logging system
            #
            # +object+ can be
            # * a deployment model, in which case no task  in this deployment
            #   will be logged
            # * a task model, in which case no port of any task of this type
            #   will be logged
            # * a port model, in which case no such port will be logged
            #   (regardless of which task it is on)
            # * a string. It can then either be a task name, a port name or a type
            #   name
            def exclude_from_log(object, subname = nil)
                main_group.add(object, subname)
            end

            # Turns logging on for the named group. The modification will only
            # be applied at the next network generation.
            #
            # Groups are declared with {#log_group}
            #
            # @raise [ArgumentError] if no group with this name exists
            def enable_log_group(name)
	        name = name.to_s
	        if !log_groups.has_key?(name)
		    raise ArgumentError, "no such log group #{name}. Available groups are: #{log_groups.keys.join(", ")}"
		end
                log_groups[name].enabled = true
            end

            # Turns logging off for the named group. The modification will only
            # be applied at the next network generation.
            #
            # Groups are declared with {#log_group}
            #
            # @raise [ArgumentError] if no group with this name exists
            def disable_log_group(name)
	        name = name.to_s
	        if !log_groups.has_key?(name)
		    raise ArgumentError, "no such log group #{name}. Available groups are: #{log_groups.keys.join(", ")}"
		end
                log_groups[name].enabled = false
            end

            # If true, the output of the local process server will be saved in
            # log_dir/local_process_server.txt
            attr_predicate :redirect_local_process_server?, true

            # Signifies whether orocos logging is enabled at all or not. If
            # false, no logging will take place. If true, logging is enabled to
            # the extent of the log configuration done with enable/disable log
            # groups (#enable_log_group) and single ports (#exclude_from_log)
            attr_predicate :log_enabled?
            # See #log_enabled?
            def enable_logging; @log_enabled = true end
            # See #log_enabled?
            def disable_logging; @log_enabled = false end

            # If true, changes to the values in properties are being logged by
            # the framework. If false, they are not.
            #
            # Currently, properties are logged in a properties.0.log file
            attr_predicate :conf_log_enabled?
            # See #conf_log_enabled?
            def enable_conf_logging; @conf_log_enabled = true end
            # See #conf_log_enabled?
            def disable_conf_logging; @conf_log_enabled = false end

            # Returns true if +deployment+ is completely excluded from logging
            def deployment_excluded_from_log?(deployment)
                if !log_enabled?
                    true
                else
                    matches = log_groups.find_all { |_, group| group.matches_deployment?(deployment) }
                    !matches.empty? && matches.all? { |_, group| !group.enabled? }
                end
            end

            # Returns true if the port with name +port_name+ of task model
            # +task_model+ in deployment +deployment+ should be logged or not
            def port_excluded_from_log?(deployment, port)
                if !log_enabled?
                    true
                else
                    matches = log_groups.find_all { |_, group| group.matches_port?(deployment, port) }
                    !matches.empty? && matches.all? { |_, group| !group.enabled? }
                end
            end

            # If multiple deployments are available for a task, and this task is
            # not a device driver, the resolution engine will randomly pick one
            # if this flag is set to false (the default). If set to true, it
            # will generate an error
            attr_predicate :reject_ambiguous_deployments?, true

            # If true (the default), the runtime management will automatically
            # configure the tasks. If not, it will wait for you (or other
            # processes) to do it manually
            attr_predicate :auto_configure?, true

            # In normal operations, the plugin initializes the CORBA layer,
            # which takes some time.
            #
            # In some tools, one only wants to manipulate models offline. In
            # which case we don't need to waste time initializing the layer.
            #
            # Set this value to true to avoid initializing the CORBA layer
            attr_predicate :only_load_models?, true

            # In normal operations, a local proces server called 'localhost' is
            # automatically started on the local machine. If this predicate is
            # set to true, using self.orocos_disables_local_process_server = true), then
            # this will be disabled
            #
            # See also #orocos_process_server
            attr_predicate :disables_local_process_server?, true

            # If true, all deployments declared with use_deployment or
            # use_deployments_from are getting started at the very beginning of
            # the execution
            #
            # This greatly reduces latency during operations
            attr_predicate :start_all_deployments?, true

            # If set to a non-nil value, the deployment processes will be
            # started with the given prefix
            #
            # It is set from the syskit.prefix configuration variable in app.yml
            #
            # @return [String,nil]
            attr_accessor :prefix

            # True if deployments are going to be started with a prefix
            def prefixing?; !!prefix end

            # A set of regular expressions that should match the names of the
            # deployments that should not be prefixed even if {#prefix} is set
            #
            # It is set from the syskit.prefix_blacklist configuration variable in app.yml
            #
            # @return [Array<String,Regexp>]
            attr_reader :prefix_blacklist

            # If set, it is the service discovery domain in which the orocos
            # processes should be published
            #
            # It is set from the syskit.sd_domain configuration variable in app.yml
            #
            # @return [String]
            attr_accessor :sd_domain

            # A set of regular expressions that should match the names of the
            # deployments that should be published on DNS-SD if {#sd_domain} is
            # set
            #
            # It is set from the syskit.sd_publish_list configuration variable in app.yml
            #
            # @return [Array<String,Regexp>]
            attr_reader :sd_publish_list

            # The set of known deployments on a per-process-server basis
            #
            # @return [Hash<String,[ConfiguredDeployment]>]
            attr_reader :deployments

            # A mapping from a task name to the deployment that provides it
            #
            # @return [{String => Models::ConfiguredDeployment}]
            attr_reader :deployed_tasks

            # Margin added to computed buffer sizes
            #
            # The final buffer size is computed_size * margin rounded upwards.
            # The default is 10% (0.1)
            #
            # @return [Float]
            attr_reader :buffer_size_margin

            # The set of known process servers.
            #
            # It maps the server name to the Orocos::ProcessServer instance
            attr_reader :process_servers

            # Ensures that a ruby process server is present with the given name
            #
            # It is used when running in simulation mode, to "fake" the task
            # contexts
            #
            # @param [String] name the name of the original process server
            # @return [ProcessServerConfig] the registered process server
            def sim_process_server(name)
                sim_name = "#{name}-sim"
                if !process_servers[sim_name]
                    loader = process_server_config_for(name).loader
                    mng = Orocos::RubyTasks::ProcessManager.new(loader)
                    register_process_server(sim_name, mng, "")
                end
                process_server_config_for(sim_name)
            end

            # Declare deployed versions of some Ruby tasks
            def use_ruby_tasks(mappings)
                use_deployments(mappings.merge(:on => 'ruby_tasks'))
            end

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            def use_deployment(*names)
                if !names.last.kind_of?(Hash)
                    names << Hash.new
                end
                options, run_options = Kernel.filter_options names.pop,
                    :on => 'localhost'
                process_server_name = options[:on]
                process_server_config =
                    if app.simulation?
                        sim_process_server(process_server_name)
                    else
                        process_server_config_for(process_server_name)
                    end
                options[:on] = process_server_config.name
                run_options[:loader] = process_server_config.loader

                deployments_by_name = Hash.new
                names = names.map do |n|
                    if n.respond_to?(:orogen_model)
                        deployments_by_name[n.orogen_model.name] = n
                        n.orogen_model
                    else n
                    end
                end
                run_options = run_options.map_key do |k|
                    if k.respond_to?(:orogen_model)
                        deployments_by_name[k.orogen_model.name] = k
                        k.orogen_model
                    else k
                    end
                end

                new_deployments, _ = Orocos::Process.parse_run_options(*names, run_options)
                new_deployments.each do |deployment_name, mappings, name, spawn_options|
                    model = deployments_by_name[deployment_name] ||
                        app.using_deployment(deployment_name, options)
                    model.default_run_options.merge!(default_run_options(model))

                    configured_deployment = Models::ConfiguredDeployment.
                        new(process_server_config.name, model, mappings, name, spawn_options)
                    register_configured_deployment(configured_deployment)
                end
                model
            end

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
                deployments[configured_deployment.process_server_name] << configured_deployment
            end

            # Add all the deployments defined in the given oroGen project to the
            # set of deployments that the engine can use.
            #
            # @option options [String] :on the name of the process server this
            #   project should be loaded from
            # @return [Array<Model<Deployment>>] the set of deployments
            # @see #use_deployment
            def use_deployments_from(project_name, options = Hash.new)
                Syskit.info "using deployments from #{project_name}"
                orogen = app.using_task_library(project_name, options)

                result = []
                orogen.deployers.each_value do |deployment_def|
                    if deployment_def.install?
                        Syskit.info "  #{deployment_def.name}"
                        # Currently, the supervision cannot handle orogen_default tasks 
                        # properly, thus filtering them out for now 
                        result << use_deployment(deployment_def, options)
                    end
                end
                result
            end

            # Returns the set of options that should be given to Process.spawn
            # to start the given deployment model
            #
            # @return {String=>String} the set of default options that should be
            #   used when starting the given deployment
            def default_run_options(deployment_model)
                result = Hash.new
                if prefix = default_prefix(deployment_model)
                    result["prefix"] = prefix
                end
                if sd_domain = default_sd_domain(deployment_model)
                    result["sd-domain"] = sd_domain
                end
                result
            end

            # Returns the deployment prefix that should be used to start the
            # given syskit deployment process
            #
            # @return [String,nil] the prefix that should be used when starting
            #   this deployment, or nil if there should be none
            def default_prefix(deployment_model)
                return if !prefix
                deployment_name = deployment_model.deployment_name

                exclude = prefix_blacklist.any? do |pattern|
                    pattern === deployment_name
                end
                if !exclude
                    "#{prefix}_"
                end
            end

            # Sets up mDNS support for the syskit deployment processes
            #
            # @return [String,nil] the SD domain on which this deployment should
            #   be published, or nil if none
            def default_sd_domain(deployment_model)
                return if !sd_domain
                deployment_name = deployment_model.name

                publish = publish_white_list.any? do |pattern|
                    pattern === deployment_name
                end
                if publish
                    sd_domain
                end
            end

            # Returns the process server object named +name+
            #
            # @param [String] name the process server name
            # @raise [ArgumentError] if no such process server exists
            # @return [ProcessServerConfig]
            def process_server_config_for(name)
                config = process_servers[name]
                if config then config
                else
                    raise ArgumentError, "there is no registered process server called #{name}"
                end
            end

            # Returns the process server object named +name+
            #
            # @param (see #process_server_config_for)
            # @raise (see #process_server_config_for)
            # @return [Object] an object that conforms to orocos.rb's process
            #   server API
            def process_server_for(name)
                process_server_config_for(name).client
            end

            # Returns the log dir for the given process server
            #
            # @param [String] name the process server name
            # @raise [ArgumentError] if no such process server exists
            def log_dir_for(name)
                process_server_config_for(name).log_dir
            end

            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            # Enumerates all available process servers
            #
            # @yieldparam [Object] process_server the registered process server,
            #   as an object that conforms to orocos.rb's process server API
            # @return [void]
            def each_process_server
                return enum_for(__method__) if !block_given?
                process_servers.each_value do |config|
                    yield(config.client)
                end
            end

            # Enumerates the registration information for all known process servers
            #
            # @yieldparam [ProcessServerConfig] process_server the registered process server,
            #   as an object that conforms to orocos.rb's process server API
            # @return [void]
            def each_process_server_config(&block)
                process_servers.each_value(&block)
            end

            # @deprecated use {#connect_to_orocos_process_server} instead
            def process_server(*args)
                connect_to_orocos_process_server(*args)
            end

            ModelOnlyServer = Struct.new :loader do
                def wait_termination(timeout = 0)
                    []
                end
                def disconnect
                end
            end

            # Call to declare a new process server and add to the set of servers that
            # can be used by this plan manager
            #
            # If 'host' is set to localhost, it disables the automatic startup
            # of the local process server (i.e. sets
            # orocos_disables_local_process_server to false)
            #
            # @return [Orocos::ProcessClient,Orocos::Generation::Project]
            #
            # @raise [ArgumentError] if host is not 'localhost' and
            #   {#local_only?} is set
            # @raise [ArgumentError] if there is already a process server
            #   registered with that name
            def connect_to_orocos_process_server(name, host, options = Hash.new)
                if only_load_models? || (app.simulation? && app.single?)
                    client = ModelOnlyServer.new(Orocos.default_loader)
                    register_process_server(name, client, app.log_dir)
                    return client
                elsif app.single?
                    client = Orocos::ProcessClient.new('localhost')
                    register_process_server(name, client, app.log_dir)
                    return client
                end

                if local_only? && host != 'localhost'
                    raise ArgumentError, "in local only mode"
                elsif process_servers[name]
                    raise ArgumentError, "there is already a process server called #{name} running"
                end

                options = Kernel.validate_options options,
                    :port => Orocos::ProcessServer::DEFAULT_PORT,
                    :log_dir => 'logs',
                    :result_dir => 'results'

                port = options[:port]
                if host =~ /^(.*):(\d+)$/
                    host = $1
                    port = Integer($2)
                end

                if host == 'localhost'
                    self.disables_local_process_server = true
                end

                client = Orocos::ProcessClient.new(host, port)
                client.save_log_dir(options[:log_dir], options[:result_dir])
                client.create_log_dir(options[:log_dir], Roby.app.time_tag)
                register_process_server(name, client, options[:log_dir])
                client
            end

            ProcessServerConfig = Struct.new :name, :client, :log_dir, :callback do
                def loader
                    if client
                        client.loader
                    end
                end
            end

            # Make a process server available to syskit
            #
            # @param [String] name the process server name
            # @param [Object] client the process server client object, which has
            #   to conform to the API of {Orocos::Remotes::Client}
            # @param [String] log_dir the path to the server's log directory
            # @return [ProcessServerConfig]
            def register_process_server(name, client, log_dir)
                if process_servers[name]
                    raise ArgumentError, "there is already a process server registered as #{name}, call #remove_process_server first"
                end

                ps = ProcessServerConfig.new(name, client, log_dir)
                ps.callback = ps.loader.on_project_load do |project|
                    app.project_define_from_orogen(project)
                end
                process_servers[name] = ps
                reload_deployments_for(name)
                ps
            end

            # Reloads all deployment models
            def reload_deployments
                names = deployments.keys
                names.each do |process_server_name|
                    reload_deployments_for(process_server_name)
                end
            end

            # Reloads the deployments that have been declared for the given
            # process server
            def reload_deployments_for(process_server_name)
                pending_deployments = clear_deployments_for(process_server_name)
                pending_deployments.each do |d|
                    app.using_task_library(d.model.orogen_model.project.name, :on => process_server_name)
                    model = app.using_deployment(d.model.orogen_model.name, :on => process_server_name)
                    d = Models::ConfiguredDeployment.new(
                        process_server_name, model,
                        d.name_mappings, d.process_name, d.spawn_options)
                    register_configured_deployment(d)
                end
            end

            # Deregisters deployments that are coming from a given process
            # server
            #
            # @param [String] process_server_name the name of the process server
            # @return [Array<Models::ConfiguredDeployment>] the set of
            #   configured deployments that were registered
            def clear_deployments_for(process_server_name)
                registered_deployments = deployments.delete(process_server_name) ||
                    Array.new

                registered_deployments.each do |d|
                    d.each_orogen_deployed_task_context_model do |task|
                        if deployed_tasks[task.name] == d
                            deployed_tasks.delete(task.name)
                        end
                    end
                end
                registered_deployments
            end

            # Deregisters a process server
            #
            # @param [String] name the process server name, as given to
            #   {register_process_server}
            # @raise ArgumentError if there is no process server with that name
            def remove_process_server(name)
                ps = process_servers.delete(name)
                if !ps
                    raise ArgumentError, "there is no registered process server called #{name}"
                end

                ps.loader.remove_project_load_callback(ps.callback)
                clear_deployments_for(name)
                if app.simulation? && process_servers["#{name}-sim"]
                    remove_process_server("#{name}-sim")
                end
                ps
            end
        end
    end
end

