# frozen_string_literal: true

Robot.requires do
    using_task_library "reload"
    Syskit.conf.use_unmanaged_task OroGen.reload.Task => "task"
end

class Interface < Roby::Interface::CommandLibrary
    def orogen_model_reloaded?
        [!!OroGen.reload.Task.find_output_port("test"),
         "reloaded model was expected to have a 'test' output port, but does not"]
    end

    def orogen_deployment_exists?
        reload_model = OroGen.reload.Task
        result = Syskit.conf.deployment_group.each_configured_deployment.any? do |d|
            d.process_server_name == "unmanaged_tasks" &&
                d.each_orogen_deployed_task_context_model.any? do |t|
                    (t.task_model == reload_model.orogen_model) && t.name == "task"
                end
        end

        [result, "could not find the 'task' task of model #{reload_model}"]
    end
end
Roby::Interface::Interface.subcommand "unit_tests",
                                      Interface, "Commands used by unit tests"
