# frozen_string_literal: true

require "roby/interface/protocol"

module Syskit
    module Interface
        # Syskit extensions to Roby's interface wire protocol
        module Protocol
            Deployment = Struct.new :name, :state, :on, :pid, :ready_since,
                                    :task_id, :iors, keyword_init: true

            def self.marshal_deployment_task(task)
                if (ready_since = task.ready_event.last&.time)
                    ready_since = ready_since.tv_sec
                end

                Protocol::Deployment.new(
                    name: task.process_name,
                    state: task.current_state,
                    on: task.arguments[:on],
                    pid: task.pid,
                    ready_since: ready_since,
                    task_id: task.droby_id.id,
                    iors: task.remote_task_handles.transform_values { _1.handle.ior }
                )
            end
        end
    end
end
