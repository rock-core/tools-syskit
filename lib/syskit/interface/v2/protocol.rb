# frozen_string_literal: true

require "roby/interface/v2"

module Syskit
    module Interface
        module V2
            # Syskit extensions to Roby's v2 interface wire protocol
            module Protocol
                ROBY_TASK_MEMBERS = Roby::Interface::V2::Protocol::Task.new.members

                SystemDefinitions =
                    Struct.new(:orogen_models, :registry, keyword_init: true)

                # Marshal information from an orogen loader's into a SystemDefinitions
                # struct
                def self.marshal_system_definitions(loader)
                    registry = marshal_typelib_registry(loader.registry)
                    orogen_models = loader.loaded_task_models.each_value.map do |m|
                        marshal_orogen_model(m)
                    end

                    SystemDefinitions.new(
                        orogen_mogels: orogen_models, registry: registry
                    )
                end

                OroGenDynamicPortModel =
                    Struct.new(:name_pattern, :type_name, :input, keyword_init: true)
                OroGenPortModel =
                    Struct.new(:name, :type_name, :input, keyword_init: true)
                OroGenPropertyModel = Struct.new(:name, :type_name, keyword_init: true)
                OroGenAttributeModel = Struct.new(:name, :type_name, keyword_init: true)
                OroGenModel = Struct.new(
                    :name, :project_name, :states,
                    :properties, :attributes, :ports, :dynamic_ports,
                    keyword_init: true
                )

                def self.marshal_orogen_model_dynamic_ports(task_model)
                    task_model.each_dynamic_port.map do |model|
                        OroGenDynamicPortModel.new(
                            name_pattern: model.name,
                            type_name: model.type.name, input: model.input?
                        )
                    end
                end

                def self.marshal_orogen_model_ports(task_model)
                    task_model.each_port.map do |model|
                        OroGenPortModel.new(
                            name: model.name, type_name: model.type.name,
                            input: model.input?
                        )
                    end
                end

                def self.marshal_orogen_model_properties(task_model)
                    task_model.each_property.map do |model|
                        OroGenPropertyModel.new(
                            name: model.name, type_name: model.type.name
                        )
                    end
                end

                def self.marshal_orogen_model_attributes(task_model)
                    task_model.each_attribute.map do |model|
                        OroGenAttributeModel.new(
                            name: model.name, type_name: model.type.name
                        )
                    end
                end

                def self.marshal_orogen_model(model)
                    states = model.each_state.to_a
                    ports = marshal_orogen_model_ports(model)
                    dynamic_ports = marshal_orogen_model_dynamic_ports(model)
                    properties = marshal_orogen_model_properties(model)
                    attributes = marshal_orogen_model_attributes(model)

                    OroGenModel.new(
                        name: model.name, project_name: model.project.name,
                        states: states,
                        properties: properties, attributes: attributes,
                        ports: ports, dynamic_ports: dynamic_ports
                    )
                end

                TypelibRegistry = Struct.new :xml, keyword_init: true
                def self.marshal_typelib_registry(registry)
                    TypelibRegistry.new(xml: registry.to_xml)
                end

                DeviceModel = Struct.new(:name, keyword_init: true)
                MasterDeviceInstance = Struct.new(:name, :model, keyword_init: true) do
                    def pretty_print(pp)
                        pp.text "#{name}_dev[#{model.name}]"
                    end
                end

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
                    protocol.add_marshaller(
                        Syskit::Robot::MasterDeviceInstance,
                        &method(:marshal_master_device_instance)
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
            end
        end
    end
end
