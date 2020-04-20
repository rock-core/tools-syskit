# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Robot
        describe MasterDeviceInstance do
            describe "#==" do
                attr_reader :device, :device_m, :driver_m, :robot_m
                before do
                    @device_m = Device.new_submodel
                    @driver_m = TaskContext.new_submodel
                    driver_m.driver_for device_m, as: "dev"

                    @robot_m = RobotDefinition.new
                    @device = robot_m.device device_m, as: "test", using: driver_m
                end
                it "returns false for an object that is not a MasterDeviceInstance" do
                    refute(device == Object.new)
                end
                it "returns false if the robot object differs" do
                    other_robot_m = RobotDefinition.new
                    other_device = other_robot_m.device(
                        device_m, as: "test", using: driver_m
                    )
                    refute(device == other_device)
                end
                it "returns false if the name differs" do
                    other_device = robot_m.device(
                        device_m, as: "other_test", using: driver_m
                    )
                    refute(device == other_device)
                end
                it "returns if this is the device of a given name "\
                   "on the same robot object" do
                    mock = flexmock(kind_of?: true, robot: robot_m, name: device.name)
                    assert(device == mock)
                end
            end

            describe "#attach_to" do
                before do
                    @com_bus_m = Syskit::ComBus.new_submodel(
                        name: "ComBus", message_type: "/double"
                    )
                    @dev_m = Syskit::Device.new_submodel(name: "ComBus")
                    @com_bus_driver_m = Syskit::TaskContext.new_submodel
                    @com_bus_driver_m.driver_for @com_bus_m, as: "driver"
                    @dev_driver_m = Syskit::TaskContext.new_submodel(name: "Driver") do
                        input_port "bus_in", "/double"
                        output_port "bus_out", "/double"
                    end
                    @dev_driver_m.driver_for @dev_m, as: "driver"

                    robot = RobotDefinition.new
                    @com_bus = robot.com_bus @com_bus_m, as: "com_bus"
                    @device = robot.device @dev_m, as: "dev"
                end

                it "registers the com bus attachment on the device" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to @com_bus
                    assert @device.attached_to?(@com_bus)
                end

                it "registers the device attachment on the com bus" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to @com_bus
                    assert_equal [@device], @com_bus.each_attached_device.to_a
                end

                it "accepts a com bus object" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to @com_bus
                    assert @device.attached_to?(@com_bus)
                end

                it "resolves a com bus as name" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to "com_bus"
                    assert @device.attached_to?(@com_bus)
                end

                it "resolves the bus-to-client and client-to-bus services" do
                    flexmock(@device).should_receive(:resolve_combus_client_srv)
                                     .with(@com_bus_m::ClientInSrv, nil,
                                           @com_bus, "bus_to_client").once
                                     .and_return(bus_to_client = flexmock)
                    flexmock(@device).should_receive(:resolve_combus_client_srv)
                                     .with(@com_bus_m::ClientOutSrv, nil,
                                           @com_bus, "client_to_bus").once
                                     .and_return(client_to_bus = flexmock)
                    @device.attach_to(@com_bus)
                    assert_equal bus_to_client, @device.combus_client_in_srv
                    assert_equal client_to_bus, @device.combus_client_out_srv
                end

                it "uses the bus-to-client and client-to-bus options as service "\
                   "names if they are strings" do
                    flexmock(@device).should_receive(:resolve_combus_client_srv)
                                     .with(@com_bus_m::ClientInSrv, "in_name",
                                           @com_bus, "bus_to_client").once
                                     .and_return(bus_to_client = flexmock)
                    flexmock(@device).should_receive(:resolve_combus_client_srv)
                                     .with(@com_bus_m::ClientOutSrv, "out_name",
                                           @com_bus, "client_to_bus").once
                                     .and_return(client_to_bus = flexmock)
                    @device.attach_to(
                        @com_bus, bus_to_client: "in_name",
                                  client_to_bus: "out_name"
                    )
                    assert_equal bus_to_client, @device.combus_client_in_srv
                    assert_equal client_to_bus, @device.combus_client_out_srv
                end

                it "selects an existing common in+out services on the driver" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to "com_bus"
                    assert_equal @dev_driver_m.bus_srv.as(@com_bus_m::ClientOutSrv),
                                 @device.combus_client_out_srv
                    assert_equal @dev_driver_m.bus_srv.as(@com_bus_m::ClientInSrv),
                                 @device.combus_client_in_srv
                    assert @device.client_to_bus?
                    assert @device.bus_to_client?
                end

                it "selects distinct in and out services on the driver" do
                    @dev_driver_m.provides @com_bus_m::ClientOutSrv, as: "bus_out"
                    @dev_driver_m.provides @com_bus_m::ClientInSrv, as: "bus_in"
                    @device.attach_to "com_bus"
                    assert_equal @dev_driver_m.bus_out_srv, @device.combus_client_out_srv
                    assert_equal @dev_driver_m.bus_in_srv, @device.combus_client_in_srv
                    assert @device.client_to_bus?
                    assert @device.bus_to_client?
                end

                it "allows to disable the bus-to-client communication" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to "com_bus", bus_to_client: false
                    assert_equal @dev_driver_m.bus_srv.as(@com_bus_m::ClientOutSrv),
                                 @device.combus_client_out_srv
                    assert_nil @device.combus_client_in_srv
                    assert @device.client_to_bus?
                    refute @device.bus_to_client?
                end

                it "accepts devices that have only client-to-bus communication" do
                    @dev_driver_m.provides @com_bus_m::ClientOutSrv, as: "bus_out"
                    @device.attach_to "com_bus", bus_to_client: false
                    assert_nil @device.combus_client_in_srv
                    assert_equal @dev_driver_m.bus_out_srv, @device.combus_client_out_srv
                    assert @device.client_to_bus?
                    refute @device.bus_to_client?
                end

                it "allows to disable the client-to-bus communication" do
                    @dev_driver_m.provides @com_bus_m::ClientSrv, as: "bus"
                    @device.attach_to "com_bus", client_to_bus: false
                    assert_nil @device.combus_client_out_srv
                    assert_equal @dev_driver_m.bus_srv.as(@com_bus_m::ClientInSrv),
                                 @device.combus_client_in_srv
                    refute @device.client_to_bus?
                    assert @device.bus_to_client?
                end

                it "accepts devices that have only bus-to-client communication" do
                    @dev_driver_m.provides @com_bus_m::ClientInSrv, as: "bus_in"
                    @device.attach_to "com_bus", client_to_bus: false
                    assert_nil @device.combus_client_out_srv
                    assert_equal @dev_driver_m.bus_in_srv, @device.combus_client_in_srv
                    refute @device.client_to_bus?
                    assert @device.bus_to_client?
                end

                describe "resolve_combus_client_srv" do
                    before do
                        @srv_m = Syskit::DataService.new_submodel(name: "ClientInSrv")
                    end

                    it "raises if the expected service is not available" do
                        e = assert_raises(ArgumentError) do
                            @device.resolve_combus_client_srv(
                                @srv_m, nil, @com_bus, "bus_to_client"
                            )
                        end
                        assert_equal "Driver does not provide a service "\
                                     "of type ClientInSrv, needed "\
                                     "to connect to the bus 'com_bus'. Either disable "\
                                     "the bus-to-client communication by passing "\
                                     "bus_to_client: false, or change Driver's "\
                                     "definition to provide the data service",
                                     e.message
                    end

                    it "raises if more than one service is available" do
                        @dev_driver_m.provides @srv_m, as: "srv0"
                        @dev_driver_m.provides @srv_m, as: "srv1"
                        e = assert_raises(ArgumentError) do
                            @device.resolve_combus_client_srv(
                                @srv_m, nil, @com_bus, "bus_to_client"
                            )
                        end
                        assert_equal "Driver provides more than one service "\
                                     "of type ClientInSrv "\
                                     "to connect to the bus 'com_bus'. Select "\
                                     "one explicitely using the bus_to_client option. "\
                                     "Available services: srv0, srv1",
                                     e.message
                    end

                    it "allows to explicitely select the bus-to-client service" do
                        @dev_driver_m.provides @srv_m, as: "srv0"
                        @dev_driver_m.provides @srv_m, as: "srv1"
                        srv = @device.resolve_combus_client_srv(
                            @srv_m, "srv0", @com_bus, "bus_to_client"
                        )
                        assert_equal @dev_driver_m.srv0_srv, srv
                    end

                    it "raises if the explicitly selected service does not exist" do
                        e = assert_raises(ArgumentError) do
                            @device.resolve_combus_client_srv(
                                @srv_m, "not_exist", @com_bus, "bus_to_client"
                            )
                        end
                        assert_equal "not_exist is specified as a client service on "\
                                     "device dev for combus com_bus, but it is not a "\
                                     "data service on Driver",
                                     e.message
                    end

                    it "raises if the explicitly selected service does fullfill "\
                       "the service model" do
                        @other_srv_m = Syskit::DataService.new_submodel
                        @dev_driver_m.provides @other_srv_m, as: "srv"
                        e = assert_raises(ArgumentError) do
                            @device.resolve_combus_client_srv(
                                @srv_m, "srv", @com_bus, "bus_to_client"
                            )
                        end
                        assert_equal "srv is specified as a client service on "\
                                     "device dev for combus com_bus, but it does not "\
                                     "provide the required service ClientInSrv",
                                     e.message
                    end
                end
            end

            describe "#deployed_as" do
                before do
                    @loader = OroGen::Loaders::Base.new
                    @device_m = Device.new_submodel
                    driver_m = TaskContext.new_submodel(orogen_model_name: "test::Task")
                    @driver_m = driver_m
                    @driver_m.driver_for @device_m, as: "dev"

                    default_name = OroGen::Spec::Project
                                   .default_deployment_name("test::Task")
                    @default_deployment_name = default_name
                    @deployment_m = Syskit::Deployment.new_submodel(name: "d") do
                        task default_name, driver_m.orogen_model
                    end
                    flexmock(@loader).should_receive(:deployment_model_from_name)
                                     .with(default_name)
                                     .and_return(@deployment_m.orogen_model)

                    @robot_m = RobotDefinition.new
                    @device = @robot_m.device @device_m, as: "test", using: @driver_m
                end

                it "deploys the device's driver as specified" do
                    @device.deployed_as("test", loader: @loader)
                    candidates = @device
                                 .requirements
                                 .deployment_group
                                 .find_all_suitable_deployments_for(@driver_m.new)

                    assert_equal 1, candidates.size
                    c = candidates.first
                    assert_equal "test", c.mapped_task_name
                    assert_equal(
                        { @default_deployment_name => "test",
                          "#{@default_deployment_name}_Logger" => "test_Logger" },
                        c.configured_deployment.name_mappings
                    )
                end
            end

            describe "#deployed_as_unmanaged" do
                before do
                    @device_m = Device.new_submodel
                    driver_m = TaskContext.new_submodel(orogen_model_name: "test::Task")
                    @driver_m = driver_m
                    @driver_m.driver_for @device_m, as: "dev"
                    @conf = Syskit::RobyApp::Configuration.new(Roby.app)
                    @conf.register_process_server(
                        "unmanaged_tasks", Syskit::RobyApp::UnmanagedTasksManager.new
                    )

                    @robot_m = RobotDefinition.new
                    @device = @robot_m.device @device_m, as: "test", using: @driver_m
                end

                after do
                    @conf.remove_process_server("unmanaged_tasks")
                end

                it "declares an unmanaged deployment of the its driver model" do
                    ir = @device.deployed_as_unmanaged("test", process_managers: @conf)
                    candidates = ir
                                 .deployment_group
                                 .find_all_suitable_deployments_for(@driver_m.new)

                    assert_equal 1, candidates.size
                    deployed_task = candidates.first
                    configured_deployment = deployed_task.configured_deployment
                    # This is the real thing ... Other than the process server,
                    # everything looks exactly the same
                    assert_equal "unmanaged_tasks",
                                 configured_deployment.process_server_name
                    assert_match(/Unmanaged/, configured_deployment.model.name)
                    assert_equal "test", deployed_task.mapped_task_name
                    assert_equal(
                        { "test" => "test" },
                        configured_deployment.name_mappings
                    )
                end
            end
        end
    end
end
