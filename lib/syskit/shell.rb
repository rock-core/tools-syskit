require 'roby/interface'
require 'roby/robot'
module Orocos
    module RobyPlugin
        # Extension added to the Roby remote shell interface
        # (Roby::RemoteInterface) so that the models in Orocos::RobyPlugin get
        # aliased to Orocos and the root namespace as well
        module RemoteInterfaceExtension
            def new_model(model_name, model)
                # Compositions, data services and deployments are already taken
                # care of by aliasing the Compositions, DataServices and
                # Deployments namespaces. Act only on the task models
                if model <= Orocos::RobyPlugin::TaskContext
                    model_name = model_name.gsub('Orocos::RobyPlugin::', '')
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
                Roby.plan.find_tasks(task_model).
                    each do |t|
                        Orocos.conf.save(t.orogen_task, path, name || t.orogen_task.name)
                    end
                nil
            end

            def dump_all_config(path, name = nil)
                dump_task_config(Orocos::RobyPlugin::TaskContext, path, name)
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

            # Reloads the configuration files
            def reload_config
                if File.directory?(dir = File.join(APP_DIR, 'config', 'orogen'))
                    changed = Orocos.conf.load_dir(dir)
                    mark_changed_configuration_as_not_reusable(changed)
                end
                if Roby.app.robot_name && File.directory?(dir = File.join(APP_DIR, 'config', Roby.app.robot_name, 'orogen'))
                    changed = Orocos.conf.load_dir(dir)
                    mark_changed_configuration_as_not_reusable(changed)
                end
                nil
            end

            # Require the engine to redeploy the current network. Useful to
            # apply changed configuration files
            def redeploy
                Roby.app.orocos_engine.modified!
                nil
            end

            def enable_logging_of(string)
		Conf.orocos.enable_log_group(string)
                Roby.app.orocos_engine.modified!
                nil
            end

            def disable_logging_of(string)
                Conf.orocos.disable_log_group(string)
                Roby.app.orocos_engine.modified!
                nil
            end
        end
    end
end

module Robot
    def self.orocos
        @orocos_interface ||= Orocos::RobyPlugin::ShellInterface.new(Roby.engine)
    end
end

