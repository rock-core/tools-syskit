module Syskit
    module RobyApp
        # Orocos engine configuration interface
        #
        # The main instance of this object can be accessed as Roby::Conf.orocos. For
        # instance,
        #
        #   Roby::Conf.orocos.disable_logging
        #
        # will completely disable logging (not recommended !)
        class Configuration < Roby::OpenStruct
            def initialize
                super

                @log_enabled = true
                @conf_log_enabled = true
                @redirect_local_process_server = true

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

            def enable_log_group(name)
	        name = name.to_s
	        if !log_groups.has_key?(name)
		    raise ArgumentError, "no such log group #{name}. Available groups are: #{log_groups.keys.join(", ")}"
		end
                log_groups[name].enabled = true
            end

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

            ##
            # :attr: reject_ambiguous_processor_deployments?
            #
            # If multiple deployments are available for a task, and this task is
            # not a device driver, the resolution engine will randomly pick one
            # if this flag is set to false (the default). If set to true, it
            # will generate an error
            attr_predicate :reject_ambiguous_processor_deployments?, true

            attr_predicate :auto_configure?, true

            ##
            # :attr: orocos_only_load_models?
            #
            # In normal operations, the plugin initializes the CORBA layer,
            # which takes some time.
            #
            # In some tools, one only wants to manipulate models offline. In
            # which case we don't need to waste time initializing the layer.
            #
            # Set this value to true to avoid initializing the CORBA layer
            attr_predicate :orocos_only_load_models?, true

            ##
            # :attr: orocos_disables_local_process_server?
            #
            # In normal operations, a local proces server called 'localhost' is
            # automatically started on the local machine. If this predicate is
            # set to true, using self.orocos_disables_local_process_server = true), then
            # this will be disabled
            #
            # See also #orocos_process_server
            attr_predicate :orocos_disables_local_process_server?, true

            # If true, all deployments declared with use_deployment or
            # use_deployments_from are getting started at the very beginning of
            # the execution
            #
            # This greatly reduces latency during operations
            attr_predicate :orocos_start_all_deployments?, true

            # Add the given deployment (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # The following options are allowed:
            # on::
            #   if given, it is the name of a process server as declared with
            #   Application#orocos_process_server. The deployment will be
            #   started only on that process server. It defaults to "localhost"
            #   (i.e., the local machine)
            def use_deployment(name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'

                begin
                    model = Deployment.model_for(name)
                rescue ArgumentError
                    model = load_deployment_model(name)
                end
                server   = process_server_for(options[:on])
                deployments[options[:on]] << model
            end

            # Returns the process server object named +name+
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

            # Add all the deployments defined in the given oroGen project to the
            # set of deployments that the engine can use.
            #
            # See #use_deployment
            def use_deployments_from(project_name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server = process_server_for(options[:on])
                orogen = server.load_orogen_project(project_name)

                Syskit.info "using deployments from #{project_name}"

                result = []
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install?
                        Syskit.info "  #{deployment_def.name}"
                        # Currently, the supervision cannot handle orogen_default tasks 
                        # properly, thus filtering them out for now 
                        if not /^orogen_default/ =~ "#{deployment_def.name}"
                            result << use_deployment(deployment_def.name, options)
                        end
                    end
                end
                result
            end

        end
    end
end

