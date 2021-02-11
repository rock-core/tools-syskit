# frozen_string_literal: true

require "roby/interface"
require "roby/robot"
module Syskit
    # Definition of the syskit-specific interface commands
    class ShellInterface < Roby::Interface::CommandLibrary
        # Save the configuration of all running tasks of the given model to disk
        #
        # @param [String,nil] name the section name for the new configuration.
        #   If nil, the task's orocos name will be used
        # @param [String] path the directory in which the files should be saved
        # @return [nil]
        def dump_task_config(task_model, path, name = nil)
            FileUtils.mkdir_p(path)
            plan.find_tasks(task_model)
                .each do |t|
                    Orocos.conf.save(t.orocos_task, path, name || t.orocos_task.name)
                end
            nil
        end
        command :dump_task_config, "saves configuration from running tasks into yaml files",
                :model => "the model of the tasks that should be saved",
                :path => "the directory in which the configuration files should be saved",
                :name => "(optional) if given, the name of the section for the new configuration. Defaults to the orocos task names"

        # Saves the configuration of all running tasks to disk
        #
        # @param [String] name the section name for the new configuration
        # @param [String] path the directory in which the files should be saved
        # @return [nil]
        def dump_all_config(path, name = nil)
            dump_task_config(Syskit::TaskContext, path, name)
            nil
        end
        command :dump_all_config, "saves the configuration of all running tasks into yaml files",
                :path => "the directory in which the configuration files should be saved",
                :name => "(optional) if given, the name of the section for the new configuration. Defaults to the orocos task names"

        class ShellDeploymentRestart < Roby::Task
            event :start, :controlable => true

            poll do
                if redeploy_event.pending? && !plan.syskit_has_async_resolution?
                    redeploy_event.emit
                end
            end

            event :redeploy do |context|
                Runtime.apply_requirement_modifications(plan, force: true)
            end

            forward :redeploy => :stop
        end

        # Stops deployment processes
        #
        # @param [Array<Model<Deployment>>] models if non-empty, only the
        #   deployments matching this model will be stopped, otherwise all
        #   deployments are stopped.
        def stop_deployments(*models)
            if models.empty?
                models << Syskit::Deployment
            end
            models.each do |m|
                plan.find_tasks(m)
                    .each do |task|
                        if task.kind_of?(Syskit::TaskContext)
                            task.execution_agent.stop!
                        else
                            task.stop!
                        end
                    end
            end
        end
        command :stop_deployments, "stops deployment processes",
                :models => "(optional) if given, a list of task or deployment models pointing to what should be stopped. If not given, all deployments are stopped"

        # Restarts deployment processes
        #
        # @param [Array<Model<Deployment>,Model<TaskContext>>] models if
        #   non-empty, only the deployments matching this model or the deployments
        #   supporting tasks matching the models will be restarted, otherwise all
        #   deployments are restarted.
        def restart_deployments(*models)
            protection = ShellDeploymentRestart.new
            plan.add(protection)
            protection.start!

            if models.empty?
                models << Syskit::Deployment
            end
            done = Roby::AndGenerator.new
            done.signals protection.redeploy_event

            models.each do |m|
                agents = plan.find_tasks(m).each_with_object(Set.new) do |task, result|
                    result <<
                        if task.kind_of?(Syskit::TaskContext)
                            task.execution_agent
                        else
                            task
                        end
                end

                agents.each do |agent_task|
                    agent_task.each_executed_task do |task|
                        task.stop_event.handle_with(protection)
                    end
                    done << agent_task.stop_event
                    agent_task.stop!
                end
            end
            nil
        end
        command :restart_deployments, "restarts deployment processes",
                :models => "(optional) if given, a list of task or deployment models pointing to what should be restarted. If not given, all deployments are restarted"

        # (see Application#syskit_reload_config)
        def reload_config
            app.syskit_reload_config
        end
        command :reload_config, "reloads YAML configuration files from disk",
                "You need to call the redeploy command to apply the new configuration"

        # (see Application#syskit_pending_reloaded_configurations)
        def pending_reloaded_configurations
            app.syskit_pending_reloaded_configurations
        end
        command :pending_reloaded_configurations, "returns the list of TaskContext names that are marked as needing reconfiguration",
                "They will be reconfigured on the next redeploy or system transition"

        # Require the engine to redeploy the current network
        #
        # It must be called after {#reload_config} to apply the new
        # configuration(s)
        def redeploy
            Runtime.apply_requirement_modifications(plan, force: true)
            nil
        end
        command :redeploy, "redeploys the current network",
                "It is mostly used to apply the configuration loaded with reload_config"

        def enable_log_group(string)
            Syskit.conf.logs.enable_log_group(string)
            redeploy
            nil
        end
        command :enable_logging_of, "enables a log group",
                name: "the log group name"

        # @deprecated use enable_log_group instead
        def enable_logging_of(string)
            enable_log_group(string)
        end

        def disable_log_group(string)
            Syskit.conf.logs.disable_log_group(string)
            redeploy
            nil
        end
        command :disable_log_group, "disables a log group",
                name: "the log group name"

        # @deprecated use disable_log_group instead
        def disable_logging_of(string)
            disable_log_group(string)
        end

        LoggingGroup = Struct.new(:name, :enabled)
        LoggingConfiguration = Struct.new(:port_logs_enabled, :conf_logs_enabled, :groups)
        def logging_conf
            conf = LoggingConfiguration.new(false, false, {})
            conf.port_logs_enabled = Syskit.conf.logs.port_logs_enabled?
            conf.conf_logs_enabled = Syskit.conf.logs.conf_logs_enabled?
            Syskit.conf.logs.groups.each_pair do |key, group|
                conf.groups[key] = LoggingGroup.new(key, group.enabled?)
            end
            conf
        end
        command :logging_conf, "gets the current logging configuration"

        def update_logging_conf(conf)
            if conf.port_logs_enabled
                Syskit.conf.logs.enable_port_logging
            else
                Syskit.conf.logs.disable_port_logging
            end

            if conf.conf_logs_enabled
                Syskit.conf.logs.enable_conf_logging
            else
                Syskit.conf.logs.disable_conf_logging
            end

            conf.groups.each_pair do |name, group|
                begin
                    Syskit.conf.logs.group_by_name(name).enabled = group.enabled
                rescue ArgumentError
                    Syskit.warn "tried to update a group that does not exist: #{name}"
                end
            end
            redeploy
        end
        command :update_logging_conf, "updates the current logging configuration",
                conf: "the new logging settings"
    end
end

module Robot
    def self.syskit
        @syskit_interface ||= Syskit::ShellInterface.new(Roby.app)
    end
end

Roby::Interface::Interface.subcommand "syskit", Syskit::ShellInterface, "Commands specific to Syskit"
