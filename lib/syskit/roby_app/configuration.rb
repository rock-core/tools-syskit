module Syskit
    module RobyApp
        # Syskit engine configuration interface
        #
        # The main configuration instance is accessible as Syskit.conf or (if
        # running in a Roby application) as Conf.syskit
        class Configuration < Roby::OpenStruct
            # If true, we will load the component-specific code in
            # tasks/orocos/. It is true by default
            attr_predicate :load_component_extensions, true
            # If true, files that raise an error during task library or type
            # import will be ignored. This is usually used on "root" bundles
            # (e.g. the Rock bundle) to have the benefit of GUIs like
            # system_model even though some typekits/task libraries are not
            # present
            attr_predicate :ignore_load_errors, true

            def initialize
                super

                @load_component_extensions = true
                @log_enabled = true
                @conf_log_enabled = true
                @redirect_local_process_server = true
                @default_logging_buffer_size = 25
                @reject_ambiguous_deployments = false
                @auto_configure = true
                @only_load_models = false
                @disables_local_process_server = false
                @start_all_deployments = false
                @local_only = false
                @prefix_blacklist = []
                @sd_publish_list = []
                @ignore_load_errors = false

                @log_groups = { nil => LogGroup.new(false) }

                registry = Typelib::Registry.new
                Typelib::Registry.add_standard_cxx_types(registry)
                registry.each do |t|
                    if t < Typelib::NumericType
                        main_group.names << t.name
                    end
                end

                @robot = Robot::RobotDefinition.new

            end

            def create_subfield(name)
                Roby::OpenStruct.new(model, self, name)
            end

            # The default buffer size that should be used when setting up a
            # logger connection
            #
            # Defaults to 25
            #
            # @return [Integer]
            attr_accessor :default_logging_buffer_size

            # Describes the robot. Example:
            #
            #   robot do
            #       device 'device_type'
            #       device 'device_name', :type => 'device_type'
            #   end
            #
            def robot(&block)
                if block_given?
                    @robot.instance_eval(&block)
                end
                @robot
            end

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
            def port_excluded_from_log?(deployment, task_model, port)
                if !log_enabled?
                    true
                else
                    matches = log_groups.find_all { |_, group| group.matches_port?(deployment, task_mode, port) }
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

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            def use_deployment(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'

                begin
                    model = Deployment.model_for(name)
                rescue ArgumentError
                    model = Roby.app.load_deployment_model(name)
                end
                model.default_run_options.merge!(default_run_options(model))
                deployments[options[:on]] << model
                model
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
                orogen = Roby.app.load_orogen_project(project_name, options)

                result = []
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install?
                        Syskit.info "  #{deployment_def.name}"
                        # Currently, the supervision cannot handle orogen_default tasks 
                        # properly, thus filtering them out for now 
                        if /^orogen_default/ !~ "#{deployment_def.name}"
                            result << use_deployment(deployment_def.name, options)
                        end
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
            def process_server_for(name)
                server = Syskit.process_servers[name]
                if server then return server
                else
                    if name == 'localhost' || Roby.app.single?
                        return Orocos.master_project
                    end
                    raise ArgumentError, "there is no registered process server called #{name}"
                end
            end

            # True if this application should not try to contact other
            # machines/servers
            attr_predicate :local_only?, true

            # Call to declare a new process server to to the set of servers that
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
            def process_server(name, host, options = Hash.new)
                if Roby.app.single?
                    if disables_local_process_server?
                        return Orocos.master_project
                    else
                        client = Orocos::ProcessClient.new('localhost')
                        Syskit.register_process_server(name, client, Roby.app.log_dir)
                        return client
                    end
                end

                if local_only? && host != 'localhost'
                    raise ArgumentError, "in local only mode"
                elsif Syskit.process_servers[name]
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
                Syskit.register_process_server(name, client, options[:log_dir])
                client
            end
        end
    end
end

