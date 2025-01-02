# frozen_string_literal: true

require "roby/interface/v2"

module Syskit
    module Interface
        module V2
            # Syskit extensions to Roby's v2 interface wire protocol
            module Protocol
                ROBY_TASK_MEMBERS = Roby::Interface::V2::Protocol::Task.new.members

                DeviceModel = Struct.new(:name, keyword_init: true)
                MasterDeviceInstance = Struct.new(:name, :model, keyword_init: true)
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

                TypelibValue = Struct.new(:bytes, :type_name, keyword_init: true)
                TypelibRegistry = Struct.new(:xml, keyword_init: true)

                def self.register_marshallers(protocol)
                    protocol.add_marshaller(
                        Syskit::Deployment, &method(:marshal_deployment_task)
                    )
                    protocol.add_marshaller(
                        Syskit::Robot::MasterDeviceInstance,
                        &method(:marshal_master_device_instance)
                    )
                    protocol.add_marshaller(
                        Typelib::Type,
                        &method(:marshal_typelib_value)
                    )
                    protocol.add_marshaller(
                        Typelib::Registry,
                        &method(:marshal_typelib_registry)
                    )
                    protocol.add_marshaller(
                        Interface::Commands::PropertyUpdates,
                        &method(:marshal_property_updates)
                    )
                    protocol.allow_objects(
                        Orocos::RubyTasks::TaskContext,
                        Orocos::RubyTasks::StubTaskContext
                    )
                end

                def self.marshal_device_model(model)
                    DeviceModel.new(name: model.name)
                end

                def self.marshal_master_device_instance(_channel, device)
                    MasterDeviceInstance.new(
                        name: device.name,
                        model: marshal_device_model(device.device_model)
                    )
                end

                def self.marshal_remote_task_handle(name, remote_task_handle)
                    ior = remote_task_handle.handle.ior
                    model_name = remote_task_handle.handle.model.name
                    DeployedTask.new(
                        name: name, ior: ior, orogen_model_name: model_name
                    )
                end

                def self.marshal_deployment_task(channel, task)
                    deployed_tasks =
                        task.remote_task_handles.map do |name, remote_task_handle|
                            marshal_remote_task_handle(name, remote_task_handle)
                        end

                    roby_task = Roby::Interface::V2::Protocol.marshal_task(channel, task)
                    Deployment.new(
                        **roby_task.to_h,
                        pid: task.pid,
                        ready_since: task.ready_event.last&.time,
                        deployed_tasks: deployed_tasks
                    )
                end

                def self.marshal_typelib_value(_channel, value)
                    TypelibValue.new(
                        bytes: value.to_byte_array,
                        type_name: value.class.name
                    )
                end

                def self.marshal_typelib_registry(_channel, registry)
                    TypelibRegistry.new(xml: registry.to_xml)
                end

                PropertyUpdate =
                    Struct.new :property_name, :time, :value, keyword_init: true
                PropertyUpdates =
                    Struct.new :time, :per_task_id, keyword_init: true

                # @param [Interface::Commands::PropertyUpdates] update
                def self.marshal_property_updates(channel, update)
                    per_task_id = update.per_task_id.transform_values do |v|
                        marshal_property_update(channel, v)
                    end
                    PropertyUpdates.new(time: update.time, per_task_id: per_task_id)
                end

                # @param [Interface::Commands::PropertyUpdate] update
                def self.marshal_property_update(channel, update)
                    PropertyUpdate.new(
                        property_name: property_name, time: update.time,
                        value: marshal_typelib_value(channel, update.value)
                    )
                end
            end
        end
    end
end
