# frozen_string_literal: true

require "roby/interface/core"
require "roby/robot"

module Syskit
    module Interface
        # Definition of the syskit-specific interface commands
        class Commands < Roby::Interface::CommandLibrary
            # Return information about deployments
            #
            # @return [Protocol::Deployment]
            def deployments
                plan.find_tasks(Syskit::Deployment).to_a
            end
            command :deployments,
                    "returns information about running deployments"

            # Return incremental update about deployments
            #
            # @return [Protocol::Deployment]
            def poll_ready_deployments(known: [])
                deployments =
                    plan.find_tasks(Syskit::Deployment).running.find_all(&:ready?)
                deployment_ids = deployments.map { _1.droby_id.id }
                new_deployments =
                    deployments.find_all { !known.include?(_1.droby_id.id) }
                removed_deployments =
                    known.find_all { |id| !deployment_ids.include?(id) }
                [new_deployments, removed_deployments]
            end
            command :poll_ready_deployments,
                    "incremental information about deployments"

            PropertyUpdates = Struct.new :time, :task_updates, keyword_init: true
            PropertyTaskUpdates =
                Struct.new :id, :name, :properties, keyword_init: true
            PropertyUpdate = Struct.new :name, :time, :value, keyword_init: true

            # Return property updates for some tasks since the given timestamp
            #
            # @return [PropertyUpdates] all property updates since `since`, or
            #   all properties in the plan if `since` is nil
            def poll_property_updates(task_ids: [], since: nil)
                tasks_per_id = make_object_per_id_map(
                    plan.find_tasks(Syskit::TaskContext)
                        .find_all { |t| t.pending? || t.running? }
                )

                result = task_ids.map do |id|
                    next unless (task = tasks_per_id[id])

                    updates = find_all_updated_properties_of_task(task, since: since)
                    next if updates.empty?

                    PropertyTaskUpdates.new(
                        id: id, name: task.orocos_name, properties: updates
                    )
                end
                PropertyUpdates.new(time: Time.now, task_updates: result.compact)
            end
            command :poll_property_updates,
                    "incremental information about property updates"

            # The current typelib registry
            #
            # @return [Typelib::Registry]
            def typelib_registry
                app.default_loader.registry
            end

            # Return the property updates for the given task since the timestamp
            def find_all_updated_properties_of_task(task, since: nil)
                updates = task.properties.each.map do |p|
                    next unless (update = p.last_update)
                    next if since && update.time < since

                    PropertyUpdate.new(
                        name: p.name, time: update.time, value: update.value
                    )
                end
                updates.compact
            end

            # @api private
            #
            # Helper that converts an enumerable in a id-to-object map
            def make_object_per_id_map(query)
                query.each_with_object({}) do |object, result|
                    result[object.droby_id.id] = object
                end
            end

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
            command(
                :dump_task_config,
                "saves configuration from running tasks into yaml files",
                model: "the model of the tasks that should be saved",
                path: "the directory in which the configuration files should be saved",
                name: "(optional) if given, the name of the section for the new " \
                      "configuration. Defaults to the orocos task names"
            )

            # Saves the configuration of all running tasks to disk
            #
            # @param [String] name the section name for the new configuration
            # @param [String] path the directory in which the files should be saved
            # @return [nil]
            def dump_all_config(path, name = nil)
                dump_task_config(Syskit::TaskContext, path, name)
                nil
            end
            command(
                :dump_all_config,
                "saves the configuration of all running tasks into yaml files",
                path: "the directory in which the configuration files should be saved",
                name: "(optional) if given, the name of the section for the new " \
                      "configuration. Defaults to the orocos task names"
            )

            # Task used to tell the engine that we want the deployments restarted without
            # killing the dependent networks
            class ShellDeploymentRestart < Roby::Task
                event :start, controlable: true

                poll do
                    if redeploy_event.pending? && !plan.syskit_has_async_resolution?
                        redeploy_event.emit
                    end
                end

                event :redeploy do |_context|
                    Runtime.apply_requirement_modifications(plan, force: true)
                end

                forward redeploy: :stop
            end

            # Stops deployment processes
            #
            # @param [Array<Model<Deployment>>] models if non-empty, only the
            #   deployments matching this model will be stopped, otherwise all
            #   deployments are stopped.
            def stop_deployments(*models)
                models << Syskit::Deployment if models.empty?
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
                    models: "(optional) if given, a list of task or deployment models " \
                            "pointing to what should be stopped. If not given, all " \
                            "deployments are stopped"

            # Restarts deployment processes
            #
            # @param [Array<Model<Deployment>,Model<TaskContext>>] models if
            #   non-empty, only the deployments matching this model or the deployments
            #   supporting tasks matching the models will be restarted, otherwise all
            #   deployments are restarted.
            def restart_deployments(*models)
                models << Syskit::Deployment if models.empty?
                deployments = restart_discover_deployment_tasks(models)
                protection = restart_setup_protection(deployments)

                done = Roby::AndGenerator.new
                done.signals protection.redeploy_event
                deployments.each do |task|
                    done << task.stop_event
                    task.stop!
                end
                nil
            end
            command :restart_deployments, "restarts deployment processes",
                    models: "(optional) if given, a list of task or deployment models " \
                            "pointing to what should be restarted. If not given, all " \
                            "deployments are restarted"

            # @api private
            #
            # Helper for {#restart_deployments} that lists the deployment tasks which
            #   should be restarted
            def restart_discover_deployment_tasks(models)
                tasks = models.flat_map do |m|
                    plan.find_tasks(m).map do |task|
                        if task.kind_of?(Syskit::TaskContext)
                            task.execution_agent
                        else
                            task
                        end
                    end
                end
                tasks.uniq
            end

            # @api private
            #
            # Helper for {#restart_deployments} that sets up a error handler to avoid
            # killing tasks while we restart the deployments
            def restart_setup_protection(deployment_tasks)
                protection = ShellDeploymentRestart.new
                plan.add(protection)
                protection.start!

                deployment_tasks.each do |task|
                    task.each_executed_task do |executed_task|
                        executed_task.stop_event.handle_with(protection)
                    end
                end
                protection
            end

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
            command :pending_reloaded_configurations,
                    "returns the list of TaskContext names " \
                    "that are marked as needing reconfiguration",
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
                    "It is mostly used to apply the configuration " \
                    "loaded with reload_config"

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
            LoggingConfiguration =
                Struct.new(:port_logs_enabled, :conf_logs_enabled, :groups)
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
                logs_conf = Syskit.conf.logs
                if conf.port_logs_enabled
                    logs_conf.enable_port_logging
                else
                    logs_conf.disable_port_logging
                end

                if conf.conf_logs_enabled
                    logs_conf.enable_conf_logging
                else
                    logs_conf.disable_conf_logging
                end

                conf.groups.each_pair do |name, group|
                    logs_conf.group_by_name(name).enabled = group.enabled
                rescue ArgumentError
                    Syskit.warn "tried to update a group that does not exist: #{name}"
                end
                redeploy
            end
            command :update_logging_conf, "updates the current logging configuration",
                    conf: "the new logging settings"
        end
    end
end

module Robot # :nodoc:
    # Syskit subcommand for the shell
    def self.syskit
        @syskit_interface ||= Syskit::Interface::Commands.new(Roby.app) # rubocop:disable Naming/MemoizedInstanceVariableName
    end
end

Roby::Interface::Interface.subcommand(
    "syskit", Syskit::Interface::Commands, "Commands specific to Syskit"
)
