# frozen_string_literal: true

require "roby/interface/protocol"

module Syskit
    module Interface
        # Syskit extensions to Roby's interface wire protocol
        module Protocol
            Deployment = Struct.new :name, :state, :on, :pid, :ready_since,
                                    :task_id, :deployed_tasks, keyword_init: true

            DeployedTask = Struct.new :name, :ior, :orogen_model_name, keyword_init: true

            def self.marshal_deployment_task(task)
                if (ready_since = task.ready_event.last&.time)
                    ready_since = ready_since.tv_sec
                end

                deployed_tasks = marshal_deployed_tasks(
                    task.remote_task_handles.transform_values(&:handle)
                )

                Protocol::Deployment.new(
                    name: task.process_name,
                    state: task.current_state,
                    on: task.arguments[:on],
                    pid: task.pid,
                    ready_since: ready_since,
                    task_id: task.droby_id.id,
                    deployed_tasks: deployed_tasks
                )
            end

            def self.marshal_deployed_tasks(orocos_tasks)
                orocos_tasks.each_with_object({}) do |(name, task), h|
                    h[name] = DeployedTask.new(
                        name: name, ior: task.ior,
                        orogen_model_name: task.model.name
                    )
                end
            end
        end
    end
end
