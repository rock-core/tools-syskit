require 'roby/interface'
require 'roby/robot'
module Syskit
        # Extension added to the Roby remote shell interface
        # (Roby::RemoteInterface) so that the models in Syskit get
        # aliased to Orocos and the root namespace as well
        module RemoteInterfaceExtension
            def new_model(model_name, model)
                # Compositions, data services and deployments are already taken
                # care of by aliasing the Compositions, DataServices and
                # Deployments namespaces. Act only on the task models
                if model <= Syskit::TaskContext
                    model_name = model_name.gsub('Syskit::', '')
                    namespace_name, model_name = model_name.split('::')
                    [Orocos, Object].each do |ns|
                        ns = ns.define_or_reuse(namespace_name) { Module.new }
                        ns.define_or_reuse(model_name, model)
                    end
                end
            end
        end
        Roby::RemoteInterface.include RemoteInterfaceExtension

        class ShellInterface < Roby::ShellInterface
            def dump_task_config(task_model, path, name = nil)
                FileUtils.mkdir_p(path)
                plan.find_tasks(task_model).
                    each do |t|
                        Orocos.conf.save(t.orocos_task, path, name || t.orocos_task.name)
                    end
                nil
            end

            def dump_all_config(path, name = nil)
                dump_task_config(Syskit::TaskContext, path, name)
                nil
            end

            def mark_changed_configuration_as_not_reusable(changed)
                Roby.execute do
                    TaskContext.configured.each do |task_name, (orogen_model, current_conf)|
                        changed_conf = changed[orogen_model.name]
                        if changed_conf && current_conf.any? { |section_name| changed_conf.include?(section_name) }
                            Robot.info "task #{task_name} needs reconfiguration"
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

            # Stops all deployment processes
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

            # Either restarts deployments that support the given task contexts,
            # or the deployments of the given model.
            #
            # If no deployments are given, restart all of them
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
                        agents = ValueSet.new
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

            # Reloads the configuration files
            def reload_config
                Roby.app.find_dirs('config', 'orogen','ROBOT', :all => true, :order => :specific_last).each do |dir|
                        changed = Orocos.conf.load_dir(dir)
                        mark_changed_configuration_as_not_reusable(changed)
                end
                nil
            end

            # Require the engine to redeploy the current network. Useful to
            # apply changed configuration files
            def redeploy
                engine.execute do
                    plan.syskit_engine.resolve
                end
                nil
            end

            def enable_logging_of(string)
		Syskit.conf.enable_log_group(string)
                redeploy
                nil
            end

            def disable_logging_of(string)
                Syskit.conf.disable_log_group(string)
                redeploy
                nil
            end
        end
end

module Robot
    def self.orocos
        @orocos_interface ||= Syskit::ShellInterface.new(Roby.engine)
    end
end

