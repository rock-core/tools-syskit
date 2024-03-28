# frozen_string_literal: true

module Syskit
    module Interface
        module V2
            # Syskit extensions to Roby's v2 interface wire protocol
            module Protocol
                Deployment = Struct.new(
                    :roby_task, :pid, :ready_since, :iors, keyword_init: true
                ) do
                    def pretty_print(pp)
                        roby_task.pretty_print(pp)
                        pp.breakable
                        pp.text "PID: #{pid}"
                        pp.breakable
                        pp.text "Deployed tasks: #{iors.keys.join(', ')}"
                    end
                end

                def self.register_marshallers(protocol)
                    protocol.add_marshaller(
                        Syskit::Deployment, &method(:marshal_deployment_task)
                    )
                end

                def self.marshal_deployment_task(channel, task)
                    Deployment.new(
                        roby_task: Roby::Interface::V2::Protocol.marshal_task(
                            channel, task
                        ),
                        pid: task.pid,
                        ready_since: task.ready_event.last&.time,
                        iors: task.remote_task_handles.transform_values { _1.handle.ior }
                    )
                end
            end
        end
    end
end
