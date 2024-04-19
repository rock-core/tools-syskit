# frozen_string_literal: true

require "roby/interface/v2"

module Syskit
    module Interface
        module V2
            # Syskit extensions to Roby's v2 interface wire protocol
            module Protocol
                ROBY_TASK_MEMBERS = Roby::Interface::V2::Protocol::Task.new.members

                Deployment = Struct.new(
                    *ROBY_TASK_MEMBERS,
                    :pid, :ready_since, :deployed_tasks, keyword_init: true
                ) do
                    def pretty_print(pp)
                        roby_task = ROBY_TASK_MEMBERS.map do |name|
                            [name, self[name]]
                        end
                        Roby::Interface::V2::Protocol::Task
                            .new(**Hash[roby_task])
                            .pretty_print(pp)
                        pp.breakable
                        pp.text "PID: #{pid}"
                        pp.breakable
                        names = deployed_tasks.map(&:name)
                        pp.text "Deployed tasks: #{names.join(', ')}"
                    end
                end

                DeployedTask = Struct.new(
                    :name, :ior, :orogen_model_name, keyword_init: true
                )

                def self.register_marshallers(protocol)
                    protocol.add_marshaller(
                        Syskit::Deployment, &method(:marshal_deployment_task)
                    )
                end

                def self.register_remote_task_handle(name, remote_task_handle)
                    ior = remote_task_handle.handle.ior
                    model_name = remote_task_handle.handle.model.name
                    DeployedTask.new(
                        name: name, ior: ior, orogen_model_name: model_name
                    )
                end

                def self.marshal_deployment_task(channel, task)
                    deployed_tasks =
                        task.remote_task_handles.map do |name, remote_task_handle|
                            register_remote_task_handle(name, remote_task_handle)
                        end

                    roby_task = Roby::Interface::V2::Protocol.marshal_task(channel, task)
                    Deployment.new(
                        **roby_task.to_h,
                        pid: task.pid,
                        ready_since: task.ready_event.last&.time,
                        deployed_tasks: deployed_tasks
                    )
                end
            end
        end
    end
end
