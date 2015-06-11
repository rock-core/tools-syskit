require 'roby/interface'
require 'roby/robot'
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
            plan.find_tasks(task_model).
                each do |t|
                Orocos.conf.save(t.orocos_task, path, name || t.orocos_task.name)
            end
            nil
        end
        command :dump_task_config, 'saves configuration from running tasks into yaml files',
            :model => 'the model of the tasks that should be saved',
            :path => 'the directory in which the configuration files should be saved',
            :name => '(optional) if given, the name of the section for the new configuration. Defaults to the orocos task names'

        # Saves the configuration of all running tasks to disk
        #
        # @param [String] name the section name for the new configuration
        # @param [String] path the directory in which the files should be saved
        # @return [nil]
        def dump_all_config(path, name = nil)
            dump_task_config(Syskit::TaskContext, path, name)
            nil
        end
        command :dump_all_config, 'saves the configuration of all running tasks into yaml files',
            :path => 'the directory in which the configuration files should be saved',
            :name => '(optional) if given, the name of the section for the new configuration. Defaults to the orocos task names'

        # Helper method that makes sure that changed configuration files will
        # cause the relevant tasks to be reconfigured in the next re-deployment
        def mark_changed_configuration_as_not_reusable(changed)
            Roby.execute do
                TaskContext.configured.each do |task_name, (orogen_model, current_conf)|
                    changed_conf = changed[orogen_model.name]
                if changed_conf && current_conf.any? { |section_name| changed_conf.include?(section_name) }
                    ::Robot.info "task #{task_name} needs reconfiguration"
                    TaskContext.needs_reconfiguration << task_name
                end
                end
            end
        end

        class ShellDeploymentRestart < Roby::Task
            event :start, :controlable => true
            event :stop do |context|
                plan.syskit_engine.resolve
                emit :stop
            end
        end

        # Stops deployment processes
        #
        # @param [Array<Model<Deployment>>] models if non-empty, only the
        #   deployments matching this model will be stopped, otherwise all
        #   deployments are stopped.
        def stop_deployments(*models)
            engine.execute do
                if models.empty?
                    models << Syskit::Deployment
                end
                models.each do |m|
                    plan.find_tasks(m).
                        each do |task|
                            if task.kind_of?(Syskit::TaskContext)
                                task.execution_agent.stop!
                            else
                                task.stop!
                            end
                        end
                end
            end
        end
        command :stop_deployments, 'stops deployment processes',
            :models => '(optional) if given, a list of task or deployment models pointing to what should be stopped. If not given, all deployments are stopped'

        # Restarts deployment processes
        #
        # @param [Array<Model<Deployment>,Model<TaskContext>>] models if
        #   non-empty, only the deployments matching this model or the deployments
        #   supporting tasks matching the models will be restarted, otherwise all
        #   deployments are restarted.
        def restart_deployments(*models)
            engine.execute do
                protection = ShellDeploymentRestart.new
                plan.add(protection)
                protection.start!

                if models.empty?
                    models << Syskit::Deployment
                end
                done = Roby::AndGenerator.new
                done.signals protection.stop_event

                models.each do |m|
                    agents = Set.new
                    plan.find_tasks(m).
                        each do |task|
                            if task.kind_of?(Syskit::TaskContext)
                                agents << task.execution_agent
                            else
                                agents << task
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
            end
            nil
        end
        command :restart_deployments, 'restarts deployment processes',
            :models => '(optional) if given, a list of task or deployment models pointing to what should be restarted. If not given, all deployments are restarted'

        # Reloads the configuration files
        #
        # The new configuration will only be applied to running tasks after
        # {#redeploy} is called as well
        def reload_config
            Roby.app.find_dirs('config', 'orogen','ROBOT', :all => true, :order => :specific_last).each do |dir|
                changed = Orocos.conf.load_dir(dir)
                mark_changed_configuration_as_not_reusable(changed)
            end
            nil
        end
        command :reload_config, 'reloads YAML configuration files from disk',
            'The new configuration will only be applied after the redeploy command is issued'

        # Require the engine to redeploy the current network
        #
        # It must be called after {#reload_config} to apply the new
        # configuration(s)
        def redeploy
            engine.execute do
                plan.syskit_engine.resolve
            end
            nil
        end
        command :redeploy, 'redeploys the current network',
            'It is mostly used to apply the configuration loaded with reload_config'

        # Enables the given log group
        def enable_logging_of(string)
            Syskit.conf.enable_log_group(string)
            redeploy
            nil
        end
        command :enable_logging_of, 'enables a log group',
            :name => "the log group name"

        # Disables the given log group
        def disable_logging_of(string)
            Syskit.conf.disable_log_group(string)
            redeploy
            nil
        end
        command :disable_logging_of, 'disables a log group',
            :name => "the log group name"
    end
end

module Robot
    def self.syskit
        @syskit_interface ||= Syskit::ShellInterface.new(Roby.app)
    end
end

Roby::Interface::Interface.subcommand 'syskit', Syskit::ShellInterface, 'Commands specific to Syskit'

