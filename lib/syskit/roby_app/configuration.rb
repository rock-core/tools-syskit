# frozen_string_literal: true

require "orocos/ruby_process_server"
require "orocos/remote_processes/client"
module Syskit
    module RobyApp
        # Syskit engine configuration interface
        #
        # The main configuration instance is accessible as Syskit.conf or (if
        # running in a Roby application) as Conf.syskit
        class Configuration
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
            # Controls whether the orogen types should be exported as Ruby
            # constants
            attr_predicate :export_types?, true

            # Data logging configuration
            #
            # @return [LoggingConfiguration]
            attr_reader :logs

            # Component configuration
            #
            # This returns an OpenStruct object in which component-specific
            # configuration can be stored. Each component will in
            # {TaskContext#configure} look for a value named as its deployed
            # task name and apply configuration stored there (if there is any)
            attr_reader :orocos

            # A global deployment group
            #
            # This exists for backward-compatibility reasons, to ease the
            # transition to the deployment API, as opposed to the older
            # name-based deployment management
            #
            # @return [Models::DeploymentGroup]
            attr_reader :deployment_group

            # Controls whether the orogen types should be exported as Ruby
            # constants
            #
            # @param [Boolean] flag
            def export_types=(flag)
                @export_types = flag
                app.default_loader.export_types = flag
            end

            def initialize(app)
                super()

                @app = app
                @process_servers = {}
                @load_component_extensions = true
                @redirect_local_process_server = true
                @reject_ambiguous_deployments = true
                @only_load_models = nil
                @disables_local_process_server = false
                @define_default_process_managers = true
                @local_only = false
                @permanent_deployments = true
                @prefix_blacklist = []
                @sd_publish_list = []
                @ignore_missing_orogen_projects_during_load = false
                @ignore_load_errors = false
                @buffer_size_margin = 0.1
                @use_only_model_pack = false
                clear

                self.export_types = true
            end

            def create_subfield(name)
                Roby::OpenStruct.new(model, self, name)
            end

            # Resets this Syskit configuration object
            #
            # Note that it is called by {#initialize}
            def clear
                @deployment_group = Models::DeploymentGroup.new
                @logs = LoggingConfiguration.new
                @orocos = Roby::OpenStruct.new
            end

            # Controls whether Syskit sets up its default process managers
            # (localhost, ruby_tasks, unmanaged_tasks and ros), or leaves
            # it to the app to set them up
            #
            # This is internally used during tests
            #
            # @see define_default_process_managers
            def define_default_process_managers?
                @define_default_process_managers
            end

            # (see define_default_process_managers?)
            #
            # @see define_default_process_managers?
            def define_default_process_managers=(value)
                @define_default_process_managers = value
            end

            # @deprecated access {#logs} for logging configuration
            def default_logging_buffer_size
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.default_logging_buffer_size
            end

            # @deprecated access {#logs} for logging configuration
            def default_logging_buffer_size=(size)
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.default_logging_buffer_size = size
            end

            # @deprecated access {#logs} for logging configuration
            def log_group(name, &block)
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.create_group(name) do |group|
                    group.instance_eval(&block)
                end
            end

            # Permanently exclude object from the logging system
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

            # @deprecated access {#logs} for logging configuration
            def enable_log_group(name)
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.enable_group(name)
            end

            # @deprecated access {#logs} for logging configuration
            def disable_log_group(name)
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.disable_group(name)
            end
            # If true, the output of the local process server will be saved in
            # log_dir/local_process_server.txt
            attr_predicate :redirect_local_process_server?, true

            # @deprecated access {#logs} for logging configuration
            def enable_logging
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.enable_port_logging
            end

            # @deprecated access {#logs} for logging configuration
            def disable_logging
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.disable_port_logging
            end

            # @deprecated access {#logs} for logging configuration
            def enable_conf_logging
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.enable_conf_logging
            end

            # @deprecated access {#logs} for logging configuration
            def disable_conf_logging
                Roby.warn_deprecated "logging configuration has been moved to Syskit.conf.logs (of type LoggingConfiguration)"
                logs.disable_conf_logging
            end

            # If multiple deployments are available for a task, and this task is
            # not a device driver, the resolution engine will randomly pick one
            # if this flag is set to false. If set to true (the default), it
            # will generate an error
            attr_predicate :reject_ambiguous_deployments?, true

            # If true (the default), deployments are markes as permanent, i.e.
            # won't be garbage-collected when the corresponding tasks are unused
            attr_predicate :permanent_deployments?, true

            # In normal operations, the plugin initializes the CORBA layer,
            # which takes some time.
            #
            # In some tools, one only wants to manipulate models offline. In
            # which case we don't need to waste time initializing the layer.
            #
            # Set this value to true to avoid initializing the CORBA layer
            def only_load_models=(flag)
                @only_load_models = flag
            end

            def only_load_models?
                if @only_load_models.nil?
                    app.modelling_only?
                else
                    @only_load_models
                end
            end

            # Controls whether Syskit auto-starts a process server locally
            #
            # In normal operations, a local proces server called 'localhost' is
            # automatically started on the local machine. If this predicate is
            # set to true, with Syskit.conf.disables_local_process_server = true,
            # this server won't be started.
            #
            # Disable this when the local process server is managed by other
            # means, or when the machine that runs the Syskit instance is not
            # the machine that runs the components
            #
            # The local process server won't be started if
            # {#define_default_process_managers?} is explicitely set to false
            def disables_local_process_server?
                @disables_local_process_server
            end

            # (see disables_local_process_server?)
            def disables_local_process_server=(flag)
                @disables_local_process_server = flag
            end

            # If set to a non-nil value, the deployment processes will be
            # started with the given prefix
            #
            # It is set from the syskit.prefix configuration variable in app.yml
            #
            # @return [String,nil]
            attr_accessor :prefix

            # True if deployments are going to be started with a prefix
            def prefixing?
                !!prefix
            end

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

            # If set, it is the list of deployments that should be published on
            # DNS-SD. It has no effect if {#sd_domain} is not set.
            #
            # @return [Array<#===>]
            attr_accessor :publish_white_list

            # A set of regular expressions that should match the names of the
            # deployments that should be published on DNS-SD if {#sd_domain} is
            # set
            #
            # It is set from the syskit.sd_publish_list configuration variable in app.yml
            #
            # @return [Array<String,Regexp>]
            attr_reader :sd_publish_list

            # Margin added to computed buffer sizes
            #
            # The final buffer size is computed_size * margin rounded upwards.
            # The default is 10% (0.1)
            #
            # @return [Float]
            attr_reader :buffer_size_margin

            # @deprecated use {#sim_process_server_config_for} instead for
            #   consistency with {#process_server_config_for}
            #
            # (see #sim_process_server_config_for)
            def sim_process_server(name)
                sim_process_server_config_for(name)
            end

            # Ensures that a ruby process server is present with the given name
            #
            # It is used when running in simulation mode, to "fake" the task
            # contexts
            #
            # @param [String] name the name of the original process server
            # @return [ProcessServerConfig] the registered process server
            def sim_process_server_config_for(name)
                sim_name = "#{name}-sim"
                unless process_servers[sim_name]
                    mng = Orocos::RubyTasks::ProcessManager.new(app.default_loader,
                                                                task_context_class: Orocos::RubyTasks::StubTaskContext)
                    register_process_server(sim_name, mng, "")
                end
                process_server_config_for(sim_name)
            end

            # Returns the set of options that should be given to Process.spawn
            # to start the given deployment model
            #
            # @return {String=>String} the set of default options that should be
            #   used when starting the given deployment
            def default_run_options(deployment_model)
                result = {}
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
                return unless prefix

                deployment_name = deployment_model.deployment_name

                exclude = prefix_blacklist.any? do |pattern|
                    pattern === deployment_name
                end
                unless exclude
                    "#{prefix}_"
                end
            end

            # Sets up mDNS support for the syskit deployment processes
            #
            # @return [String,nil] the SD domain on which this deployment should
            #   be published, or nil if none
            def default_sd_domain(deployment_model)
                return unless sd_domain

                deployment_name = deployment_model.name

                publish = publish_white_list.any? do |pattern|
                    pattern === deployment_name
                end
                if publish
                    sd_domain
                end
            end

            # Tests whether there is a registered process server with that name
            def has_process_server?(name)
                process_servers[name.to_str]
            end

            # Exception raised when trying to register a non-local process
            # server while {#local_only?} is set
            class LocalOnlyConfiguration < ArgumentError; end
            # Exception raised when trying to access a process manager that does
            # not exist
            class UnknownProcessServer < ArgumentError; end
            # Exception raised when trying to connect to a process manager that
            # is already connected
            class AlreadyConnected < ArgumentError; end

            # Returns the process server object named +name+
            #
            # @param [String] name the process server name
            # @raise [UnknownProcessServer] if no such process server exists
            # @return [ProcessServerConfig]
            def process_server_config_for(name)
                unless (config = process_servers[name])
                    raise UnknownProcessServer,
                          "there is no registered process server called #{name}, "\
                          "existing servers are: #{process_servers.keys.sort.join(', ')}"
                end

                config
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

            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            # Enumerates all available process servers
            #
            # @yieldparam [Object] process_server the registered process server,
            #   as an object that conforms to orocos.rb's process server API
            # @return [void]
            def each_process_server
                return enum_for(__method__) unless block_given?

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

                def disconnect; end
            end

            # Call to declare a new process server and add to the set of servers that
            # can be used by this plan manager
            #
            # If 'host' is set to localhost, it disables the automatic startup
            # of the local process server (i.e. sets
            # orocos_disables_local_process_server to true)
            #
            # @return [Orocos::ProcessClient,Orocos::Generation::Project]
            #
            # @raise [LocalOnlyConfiguration] if host is not 'localhost' and
            #   {#local_only?} is set
            # @raise [AlreadyConnected] if there is already a process server
            #   registered with that name
            def connect_to_orocos_process_server(
                name, host, port: Orocos::RemoteProcesses::DEFAULT_PORT,
                log_dir: nil, result_dir: nil, host_id: nil,
                name_service: Orocos.name_service
            )

                if log_dir || result_dir
                    Syskit.warn(
                        "specifying log and/or result dir for remote process servers "\
                        "is deprecated. Use 'syskit process_server' instead of "\
                        "'orocos_process_server' which will take the log dir "\
                        "information from the environment/configuration"
                    )
                end

                if only_load_models? || (app.simulation? && app.single?)
                    client = ModelOnlyServer.new(app.default_loader)
                    register_process_server(
                        name, client, app.log_dir, host_id: host_id || "syskit"
                    )
                    return client
                elsif app.single?
                    client = Orocos::RemoteProcesses::Client.new(
                        "localhost", port, root_loader: app.default_loader
                    )
                    register_process_server(
                        name, client, app.log_dir, host_id: host_id || "localhost"
                    )
                    return client
                end

                if local_only? && host != "localhost"
                    raise LocalOnlyConfiguration,
                          "in local only mode, one can only connect to process "\
                          "servers on 'localhost' (got #{host})"
                elsif process_servers[name]
                    raise AlreadyConnected,
                          "we are already connected to a process server called #{name}"
                end

                if (m = /^(.*):(\d+)$/.match(host))
                    host = m[1]
                    port = Integer(m[2])
                end

                self.disables_local_process_server = (host == "localhost")

                client = Orocos::RemoteProcesses::Client.new(
                    host, port,
                    root_loader: app.default_loader,
                    name_service: name_service
                )
                client.create_log_dir(
                    log_dir, Roby.app.time_tag,
                    { "parent" => Roby.app.app_metadata }
                )
                register_process_server(name, client, log_dir, host_id: host_id || name)
                client
            end

            ProcessServerConfig = Struct.new :name, :client, :log_dir, :host_id do
                def on_localhost?
                    host_id == "localhost" || host_id == "syskit"
                end

                def in_process?
                    host_id == "syskit"
                end

                def loader
                    client.loader
                end
            end

            # Make a process server available to syskit
            #
            # @param [String] name the process server name
            # @param [Object] client the process server client object, which has
            #   to conform to the API of {Orocos::Remotes::Client}
            # @param [String] log_dir the path to the server's log directory
            # @return [ProcessServerConfig]
            def register_process_server(name, client, log_dir = nil, host_id: name)
                if process_servers[name]
                    raise ArgumentError, "there is already a process server registered as #{name}, call #remove_process_server first"
                end

                ps = ProcessServerConfig.new(name, client, log_dir, host_id)
                process_servers[name] = ps
                ps
            end

            # Deregisters a process server
            #
            # @param [String] name the process server name, as given to
            #   {register_process_server}
            # @raise ArgumentError if there is no process server with that name
            def remove_process_server(name)
                ps = process_servers.delete(name)
                unless ps
                    raise ArgumentError, "there is no registered process server called #{name}"
                end

                app.default_loader.remove ps.client.loader
                if app.simulation? && process_servers["#{name}-sim"]
                    remove_process_server("#{name}-sim")
                end
                ps
            end

            def clear_deployments
                # Roby.warn_deprecated "conf.clear_deployments is deprecated, use the profile-level deployment API"
                @deployment_group = Models::DeploymentGroup.new
            end

            def use_ruby_tasks(mappings, on: "ruby_tasks", remote_task: false)
                deployment_group.use_ruby_tasks(
                    mappings, on: on, remote_task: remote_task, process_managers: self
                )
            end

            def use_unmanaged_task(mappings, on: "unmanaged_tasks")
                deployment_group.use_unmanaged_task(
                    mappings, on: on, process_managers: self
                )
            end

            def use_deployment(*names, on: "localhost", **run_options)
                Roby.sanitize_keywords_to_array(names, run_options)
                deployment_group.use_deployment(
                    *names, on: on, process_managers: self,
                            loader: app.default_loader, **run_options
                )
            end

            def use_deployments_from(*names, on: "localhost", **run_options)
                Roby.sanitize_keywords_to_array(names, run_options)
                deployment_group.use_deployment(
                    *names, on: on, process_managers: self,
                            loader: app.default_loader, **run_options
                )
            end

            def register_configured_deployment(configured_deployment)
                deployment_group.register_configured_deployment(configured_deployment)
            end
        end
    end
end
