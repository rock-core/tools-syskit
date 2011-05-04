require 'roby/interface'
require 'roby/robot'
module Orocos
    module RobyPlugin
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
            end
        end
    end
end

module Robot
    def self.orocos
        @orocos_interface ||= Orocos::RobyPlugin::ShellInterface.new(Roby.engine)
    end
end

