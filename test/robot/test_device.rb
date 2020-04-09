# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Robot::MasterDeviceInstance do
    attr_reader :task_m, :device_m
    attr_reader :device
    before do
        device_m = @device_m = Syskit::Device.new_submodel
        @task_m = Syskit::TaskContext.new_submodel do
            driver_for device_m, as: "driver"
        end
        @device = robot.device device_m, as: "dev"
    end

    describe "#doc" do
        it "sets the documentation to a given string" do
            string = flexmock(to_str: "test")
            device.doc(string)
            assert_equal "test", device.doc
        end
        it "resets the documentation to nil if given nil" do
            device.doc(nil)
            assert_nil device.doc
        end
    end

    describe "#each_fullfilled_model" do
        it "should enumerate the device's device type model as well as the submodels it provides" do
            srv_m = Syskit::DataService.new_submodel
            device_m.provides srv_m
            assert_equal [device_m, srv_m, Syskit::Device, Syskit::DataService], device.each_fullfilled_model.to_a
        end
    end

    describe "combus attachment" do
        attr_reader :combus_m, :device_m, :driver_m
        attr_reader :robot, :bus, :dev
        before do
            @device_m = Syskit::Device.new_submodel
            @combus_m = Syskit::ComBus.new_submodel message_type: "/double"
            @robot = Syskit::Robot::RobotDefinition.new
            combus_driver_m = Syskit::TaskContext.new_submodel do
                dynamic_input_port /^w\w+$/, "/double"
                dynamic_output_port /^\w+$/, "/double"
            end
            combus_driver_m.provides combus_m, as: "combus_driver"
            @bus = robot.com_bus combus_m, as: "bus0"
            @driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for device_m, as: "dev_driver"
            @dev = robot.device device_m, as: "dev0"
        end

        describe "#attach_to" do
            it "finds a combus_client_in_srv automatically if the task provides only one client_in_srv" do
                driver_m.orogen_model.input_port "combus_in", "/double"
                driver_m.provides combus_m.client_in_srv, as: "combus_in"
                dev.attach_to(bus, client_to_bus: false)
                assert_equal dev.combus_client_in_srv, driver_m.combus_in_srv
            end
            it "raises ArgumentError if more than one client-to-bus service is available and no name is explicitely given" do
                driver_m.orogen_model.input_port "combus_in", "/double"
                driver_m.provides combus_m.client_in_srv, as: "combus_in"
                driver_m.provides combus_m.client_in_srv, as: "combus2_in"
                assert_raises(ArgumentError) do
                    dev.attach_to(bus, client_to_bus: false)
                end
            end
            it "uses the client_to_bus option to disambiguate the service" do
                driver_m.orogen_model.input_port "combus_in", "/double"
                driver_m.provides combus_m.client_in_srv, as: "combus_in"
                driver_m.provides combus_m.client_in_srv, as: "combus2_in"
                dev.attach_to(bus, client_to_bus: false, bus_to_client: "combus2_in")
                assert_equal dev.combus_client_in_srv, driver_m.combus2_in_srv
            end
            it "raises ArgumentError if the expected bus-to-client service is not available" do
                driver_m.orogen_model.input_port "combus_in", "/double"
                driver_m.provides combus_m.client_in_srv, as: "combus_in"
                dev.attach_to(bus, client_to_bus: false)
                assert_equal dev.combus_client_in_srv, driver_m.combus_in_srv
            end

            it "finds a combus_client_out_srv automatically if the task provides only one client_out_srv" do
                driver_m.orogen_model.output_port "combus_out", "/double"
                driver_m.provides combus_m.client_out_srv, as: "combus_out"
                dev.attach_to(bus, bus_to_client: false)
                assert_equal dev.combus_client_out_srv, driver_m.combus_out_srv
            end
            it "raises ArgumentError if more than one client-to-bus service is available and no name is explicitely given" do
                driver_m.orogen_model.output_port "combus_out", "/double"
                driver_m.provides combus_m.client_out_srv, as: "combus_out"
                driver_m.provides combus_m.client_out_srv, as: "combus2_out"
                assert_raises(ArgumentError) do
                    dev.attach_to(bus, bus_to_client: false)
                end
            end
            it "uses the client_to_bus option to disambiguate the service" do
                driver_m.orogen_model.output_port "combus_out", "/double"
                driver_m.provides combus_m.client_out_srv, as: "combus_out"
                driver_m.provides combus_m.client_out_srv, as: "combus2_out"
                dev.attach_to(bus, bus_to_client: false, client_to_bus: "combus2_out")
                assert_equal dev.combus_client_out_srv, driver_m.combus2_out_srv
            end
            it "raises ArgumentError if the expected bus-to-client service is not available" do
                driver_m.orogen_model.output_port "combus_out", "/double"
                driver_m.provides combus_m.client_out_srv, as: "combus_out"
                dev.attach_to(bus, bus_to_client: false)
                assert_equal dev.combus_client_out_srv, driver_m.combus_out_srv
            end
            it "should raise if the driver has no I/O available for the combus" do
                assert_raises(ArgumentError) { dev.attach_to(bus) }
            end
        end

        describe "#attached_to?" do
            before do
                driver_m.orogen_model.input_port "combus_in", "/double"
                driver_m.provides combus_m.client_in_srv, as: "combus_in"
            end

            it "should return true if the device is attached to the given combus" do
                dev.attach_to(bus, client_to_bus: false)
                assert dev.attached_to?(bus)
            end
            it "should return false if the device is not attached to a combus with the given name" do
                assert !dev.attached_to?("bus0")
            end
            it "should return true if the device is not attached to the given combus" do
                assert !dev.attached_to?(bus)
            end
        end
    end

    describe "#slave" do
        it "should be able to create a slave device from a driver service slave" do
            slave_m = Syskit::DataService.new_submodel
            task_m.provides slave_m, as: "slave", slave_of: task_m.driver_srv
            slave_device = device.slave "slave"
            assert_equal device, slave_device.master_device
            assert_equal task_m.driver_srv.slave_srv, slave_device.service
        end
        it "should return existing slave devices" do
            slave_m = Syskit::DataService.new_submodel
            task_m.provides slave_m, as: "slave", slave_of: task_m.driver_srv
            slave_device = device.slave "slave"
            assert_same slave_device, device.slave("slave")
        end
    end

    describe "#method_missing" do
        it "should give access to slave devices" do
            flexmock(device).should_receive("slave").once.with("slave").and_return(obj = Object.new)
            assert_same obj, device.slave_dev
        end
    end
end

describe Syskit::Robot::SlaveDeviceInstance do
    attr_reader :task_m, :device_m, :slave_m
    attr_reader :device, :slave_device
    before do
        device_m = @device_m = Syskit::Device.new_submodel
        slave_m = @slave_m = Syskit::DataService.new_submodel
        @task_m = Syskit::TaskContext.new_submodel do
            driver_for device_m, as: "driver"
            provides slave_m, as: "slave", slave_of: "driver"
        end
        @device = robot.device device_m, as: "dev"
        @slave_device = device.slave("slave")
    end

    describe "#each_fullfilled_model" do
        it "should enumerate the device's device type model as well as the submodels it provides" do
            srv_m = Syskit::DataService.new_submodel
            slave_m.provides srv_m
            assert_equal [slave_m, srv_m, Syskit::DataService], slave_device.each_fullfilled_model.to_a
        end
    end
end
