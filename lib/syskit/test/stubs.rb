# frozen_string_literal: true

module Syskit
    module Test
        # Common features for stub creation
        class Stubs
            def initialize
                @__test_overriden_configurations = []
            end

            def dispose
                @__test_overriden_configurations.each do |model, manager|
                    model.configuration_manager = manager
                end
            end

            # Generate
            def default_stub_name
                "stub#{Stubs.stub_model_id}"
            end

            @syskit_stub_model_id = 0

            def self.stub_model_id
                @syskit_stub_model_id += 1
            end

            # Create empty configuration sections for the given task model
            def stub_conf(task_m, *conf, data: {})
                concrete_task_m = task_m.concrete_model
                protect_configuration_manager(concrete_task_m)
                conf.each do |conf_name|
                    concrete_task_m.configuration_manager.add(
                        conf_name, data, merge: true
                    )
                end
            end

            # Ensure that any modification made to a model's configuration
            # manager are undone at teardown
            def protect_configuration_manager(model)
                manager = model.configuration_manager
                model.configuration_manager = manager.dup
                @__test_overriden_configurations << [model, manager]
            end

            # Create a new stub deployment model that can deploy a given task
            # context model
            #
            # @param [Model<Syskit::TaskContext>,nil] task_model if given, a
            #   task model that should be deployed by this deployment model
            # @param [String] name the name of the deployed task as well as
            #   of the deployment. If not given, and if task_model is provided,
            #   task_model.name is used as default
            # @yield the deployment model context, i.e. a context in which the
            #   same declarations than in oroGen's #deployment statement are
            #   available
            # @return [Models::ConfiguredDeployment] the configured deployment
            def stub_deployment_model(
                task_model = nil, name = default_stub_name, register: true, &block
            )
                task_model = task_model&.to_component_model
                process_server = Syskit.conf.process_server_for("stubs")

                deployment_model = Deployment.new_submodel(name: name) do
                    task(name, task_model.orogen_model) if task_model
                    instance_eval(&block) if block
                end

                if register
                    process_server.loader.register_deployment_model(
                        deployment_model.orogen_model
                    )
                end
                deployment_model
            end

            # Create a stub device of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<Device>] model the device model
            # @param [String] as the device name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def stub_device(
                model,
                driver: stub_driver_model_for(model),
                robot: Syskit::Robot::RobotDefinition.new,
                as: default_stub_name,
                **device_options
            )
                robot.device(model, as: as, using: driver, **device_options)
            end

            # Finds a driver model for a given device model, or create one if
            # there is none
            def stub_driver_model_for(model)
                stub_requirements(model.find_all_drivers.first || model, devices: false)
            end

            # Create an InstanceRequirement instance that would allow to deploy
            # the given model
            def stub_requirements(
                model,
                recursive: true, devices: true, as: default_stub_name, &block
            )
                if model.respond_to?(:to_str)
                    model = stub_task_context_model(model, &block)
                end
                model = model.to_instance_requirements.dup

                if model.composition_model?
                    stub_composition_requirements(
                        model, recursive: recursive, as: as, devices: devices
                    )
                else
                    stub_task_context_requirements(
                        model, as: as, devices: devices
                    )
                end
            end

            # @api private
            #
            # Helper for {#syskit_stub_model}
            #
            # @param [InstanceRequirements] model
            def stub_composition_requirements(
                model, recursive: true, devices: true, as: default_stub_name
            )
                model = stub_component(model, devices: devices)
                return model unless recursive

                model.each_child do |child_name, selected_child|
                    if (selected_task = selected_child.component)
                        deployed_child = selected_task
                    else
                        child_model = selected_child.selected
                        selected_service = child_model.service
                        child_model = child_model.to_component_model
                        if child_model.composition_model?
                            deployed_child = stub_composition_requirements(
                                child_model,
                                as: "#{as}_#{child_name}", devices: devices,
                                recursive: true
                            )
                        else
                            deployed_child = stub_task_context_requirements(
                                child_model, as: "#{as}_#{child_name}", devices: devices
                            )
                        end
                        if selected_service
                            deployed_child.select_service(selected_service)
                        end
                    end
                    model.use(child_name => deployed_child)
                end
                model
            end

            # Create a stub combus of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<ComBus>] model the device model
            # @param [String] as the combus name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def stub_com_bus(
                model, driver: nil, robot: nil, as: default_stub_name,
                **device_options
            )
                robot ||= Syskit::Robot::RobotDefinition.new
                driver ||= stub_driver_model_for(model)
                robot.com_bus(model, as: as, using: driver, **device_options)
            end

            # Create a stub device attached on the given bus
            #
            # If the bus is a device object, the new device is attached to the
            # same robot model. Otherwise, a new robot model is created for both
            # the bus and the device
            #
            # @param [Model<ComBus>,MasterDeviceInstance] bus either a bus model
            #   or a bus object
            # @param [String] as a name for the new device
            # @param [Model<TaskContext>] driver the driver that should be used
            #   for the device. If not given, syskit will look for a suitable
            #   driver or stub one
            def stub_attached_device(
                bus, as: default_stub_name,
                client_to_bus: true, bus_to_client: true,
                base_model: Syskit::Device
            )
                unless bus.kind_of?(Robot::DeviceInstance)
                    bus = stub_com_bus(bus, as: "#{as}_bus")
                end
                bus_m = bus.model
                client_service_m =
                    if client_to_bus && bus_to_client
                        bus_m::ClientSrv
                    elsif client_to_bus
                        bus_m::ClientOutSrv
                    elsif bus_to_client
                        bus_m::ClientInSrv
                    else
                        raise ArgumentError, "at least one of client_to_bus or "\
                                             "bus_to_client need to be true"
                    end

                dev_m = base_model.new_submodel(name: "#{bus}-stub") do
                    provides client_service_m
                end
                dev = stub_device(dev_m, as: as)
                dev.attach_to(
                    bus, client_to_bus: client_to_bus, bus_to_client: bus_to_client
                )
                dev
            end

            # Stubs the devices required by the given model
            def stub_required_devices(model)
                model = model.to_instance_requirements
                model.model.to_component_model.each_master_driver_service do |srv|
                    unless model.arguments[:"#{srv.name}_dev"]
                        device_stub = stub_device(srv.model, driver: model.model)
                        model.with_arguments("#{srv.name}_dev": device_stub)
                    end
                end
                model
            end

            # @api private
            #
            # Helper for {#syskit_stub_requirements}
            #
            # @param [InstanceRequirements] task_m the task context model
            # @param [String] as the deployment name
            def stub_task_context_requirements(
                model, as: default_stub_name, devices: true
            )
                model = model.to_instance_requirements

                task_m = handle_abstract_component_model_in_requirements(model)
                model.add_models([task_m])
                model = stub_component(model, devices: devices)

                stub_conf(task_m, *model.arguments[:conf])

                deployment = stub_configured_deployment(task_m, as)
                model.reset_deployment_selection
                model.use_configured_deployment(deployment)
                model
            end

            def stub_component(model, devices: true)
                if devices
                    stub_required_devices(model)
                else
                    model
                end
            end

            # @api private
            #
            # Compute the concrete task model that should be used to stub an
            # instance requirement
            #
            # @param [InstanceRequirements] model
            # @return [Models::Component]
            def handle_abstract_component_model_in_requirements(model)
                task_m = model.model.to_component_model.concrete_model
                if task_m.placeholder?
                    stub_placeholder_model(task_m)
                elsif task_m.abstract?
                    stub_abstract_component_model(task_m)
                else
                    task_m
                end
            end

            # @api private
            #
            # Computes a configured deployment suitable to deploy the given task model
            def stub_configured_deployment(
                task_model = nil, task_name = default_stub_name, remote_task: false,
                &block
            )
                deployment_model = stub_deployment_model(task_model, task_name, &block)

                process_server = Syskit.conf.process_server_for("stubs")
                task_context_class =
                    if remote_task
                        Orocos::RubyTasks::RemoteTaskContext
                    else
                        process_server.task_context_class
                    end

                Models::ConfiguredDeployment.new(
                    "stubs", deployment_model, { task_name => task_name }, task_name,
                    Hash[task_context_class: task_context_class]
                )
            end

            def stub_abstract_component_model(component_m)
                component_m.new_submodel(name: "#{component_m.name}-stub")
            end

            def stub_placeholder_model(model)
                superclass = if model.superclass <= Syskit::TaskContext
                                 model.superclass
                             else Syskit::TaskContext
                             end

                services = model.proxied_data_service_models
                task_m = superclass.new_submodel(name: "#{model}-stub")
                services.each_with_index do |srv, idx|
                    srv.each_input_port do |p|
                        orocos_type_name = Orocos.find_orocos_type_name_by_type(p.type)
                        task_m.orogen_model.input_port p.name, orocos_type_name
                    end
                    srv.each_output_port do |p|
                        orocos_type_name = Orocos.find_orocos_type_name_by_type(p.type)
                        task_m.orogen_model.output_port p.name, orocos_type_name
                    end
                    if srv <= Syskit::Device
                        task_m.driver_for srv, as: "dev#{idx}"
                    else
                        task_m.provides srv, as: "srv#{idx}"
                    end
                end
                task_m
            end
        end
    end
end
