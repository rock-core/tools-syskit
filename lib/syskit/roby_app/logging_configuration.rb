# frozen_string_literal: true

module Syskit
    module RobyApp
        # Management of the configuration related to logging of data streams and
        # component configuration. The configuration for the running app can be
        # accessed from
        #
        #    Syskit.conf.logs
        #
        # Configuration logging is enabled or disabled with
        # {#enable_conf_logging} and {#disable_conf_logging}. Configuration
        # logging being low-bandwidth, there's no way to fine-tune what should
        # or should not be logged.
        #
        # Port logging can be globally disabled with {#disable_port_logging}. When
        # logging is enabled (the default, or after calling {#enable_port_logging}),
        # which ports will actually be logged is controlled by log groups. Log
        # groups match certain ports by deployment, task, port name or port
        # type. A port will be excluded from the logs if there is at least one
        # group matching it, and that all groups are disabled.
        #
        # In other words:
        #  - ports are logged if no groups match them
        #  - ports will be logged if there is at least one enabled group matching them
        #  - the only case where a port is excluded from logs is when all groups
        #    matching it are disabled
        #
        # Groups are defined with {#create_group} and enabled/disabled with
        # {#enable_group}/{#disable_group}. A new group is enabled by default.
        #
        # Logs groups are usually defined in a robot file, in a Robot.conf
        # block:
        #
        #     Robot.config do
        #       Syskit.conf.logs.create_group 'Images' do |g|
        #         g.add /base.samples.frame.Frame/
        #       end
        #     end
        #
        # From then, the Images group can be disabled programatically from
        # within the Roby app with
        #
        #     Syskit.conf.logs.disable_log_group 'Images'
        #
        # Or from the Roby shell with (note that it triggers a redeploy)
        #
        #     syskit.disable_log_group 'Images'
        #
        # And then reenabled with
        #
        #     Syskit.conf.logs.enable_log_group 'Images'
        #     syskit.enable_log_group 'Images'
        #
        # If you want to disable the group as it is being created, add
        # the enabled: false option to create_group
        #
        #     Robot.config do
        #       Syskit.conf.logs.create_group 'Images', enabled: false do |g|
        #         g.add /base.samples.frame.Frame/
        #       end
        #     end
        #
        class LoggingConfiguration
            def initialize
                @groups = {}
                @port_logs_enabled = true
                @conf_logs_enabled = true
                @default_logging_buffer_size = 25
            end

            # The set of defined groups
            #
            # @return [Hash<String,LoggingGroup>]
            attr_reader :groups

            # The default buffer size that should be used when setting up a
            # logger connection
            #
            # Defaults to 25
            #
            # @return [Integer]
            attr_accessor :default_logging_buffer_size

            # @!method conf_logs_enabled?
            #
            # If true, changes to the values in configuration values are being
            # logged by the framework. If false, they are not.
            #
            # Currently, properties are logged in a properties.0.log file
            attr_predicate :conf_logs_enabled?
            # See {#conf_log_enabled?}
            def enable_conf_logging
                @conf_logs_enabled = true
            end

            # See {#conf_log_enabled?}
            def disable_conf_logging
                @conf_logs_enabled = false
            end

            # The configuration log file
            attr_accessor :configuration_log

            # Create the configuration log file
            def create_configuration_log(path)
                @configuration_log = Pocolog::Logfiles.create(path)
            end

            # Returns the log stream that should be used for modifications to
            # the given property
            def log_stream_for(property)
                stream_name = "#{property.task_context.orocos_name}.#{property.name}"
                if !configuration_log.has_stream?(stream_name)
                    configuration_log.create_stream(
                        stream_name, property.type, property.log_metadata
                    )
                else
                    configuration_log.stream(stream_name)
                end
            end

            # @!method port_logs_enabled?
            #
            # Signifies whether ports (i.e. data streams between components) is
            # enabled at all or not. If false, no logging will take place. If
            # true, logging is enabled to the extent of the log configuration
            # done with enable/disable log groups (#enable_log_group) and single
            # ports (#exclude_from_log)
            attr_predicate :port_logs_enabled?
            # See {#log_enabled?}
            def enable_port_logging
                @port_logs_enabled = true
            end

            # See {#log_enabled?}
            def disable_port_logging
                @port_logs_enabled = false
            end

            # Fetch a group by its name
            #
            # @raise [ArgumentError] if there are no groups with this name
            # @return [LoggingGroup]
            def group_by_name(name)
                if group = groups[name.to_s]
                    group
                else raise ArgumentError, "no group named #{name}"
                end
            end

            # Create a new log group with the given name
            #
            # @param [String] name the new group name
            # @yieldparam [LoggingGroup] group the group that is being created
            #   or updated
            # @raise [ArgumentError] if the group name already exists
            def create_group(name, enabled: true)
                if groups[name.to_str]
                    raise ArgumentError, "there is already a group registered under the name #{name}, use #update_group if you mean to update it"
                end

                group = LoggingGroup.new(enabled)
                yield(group) if block_given?
                groups[name.to_str] = group
            end

            # Update an existing logging group
            #
            # @param [String] name the log group name
            # @raise (see #group_by_name)
            def update_group(name)
                yield(group_by_name(name))
            end

            # Remove a group
            def remove_group(name)
                groups.delete(name.to_str)
            end

            # @api private
            #
            # Helper method to test whether an object is excluded from log
            #
            # @yieldparam [LoggingGroup] log_group a log group
            # @yieldreturn [Boolean] whether the group matches the object whose
            #   exclusion is being considered.
            def object_excluded_from_log?
                return true unless port_logs_enabled?

                has_one_match = false

                groups.each_value do |group|
                    if yield(group)
                        return false if group.enabled?

                        has_one_match = true
                    end
                end
                has_one_match
            end

            # Returns true if the given port is excluded from logging
            #
            # @param [Port] port the port
            def port_excluded_from_log?(port)
                object_excluded_from_log? { |g| g.matches_port?(port) }
            end

            # Turns logging on for the named group. The modification will only
            # be applied at the next network generation.
            #
            # @raise (see #group_by_name)
            def enable_log_group(name)
                group_by_name(name.to_s).enabled = true
            end

            # Turns logging off for the named group. The modification will only
            # be applied at the next network generation.
            #
            # @raise (see #group_by_name)
            def disable_log_group(name)
                group_by_name(name.to_s).enabled = false
            end
        end
    end
end
