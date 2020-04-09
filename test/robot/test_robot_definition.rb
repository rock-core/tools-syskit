# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Robot::RobotDefinition do
    describe "#device" do
        attr_reader :device_m, :driver_m
        before do
            @device_m = Syskit::Device.new_submodel
            @driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for device_m, as: "driver_srv"
        end

        it "creates an object of type MasterDeviceInstance by default" do
            assert_kind_of Syskit::Robot::MasterDeviceInstance, robot.device(device_m, using: driver_m, as: "dev")
        end
        it "raises ArgumentError if given a task model that is not a driver for the device model" do
            driver_m = Syskit::TaskContext.new_submodel
            assert_raises(ArgumentError) { robot.device(device_m, using: driver_m, as: "dev") }
        end
        it "registers the new device" do
            device = robot.device(device_m, using: driver_m, as: "dev")
            assert_same device, robot.devices["dev"]
        end
        it "sets the task argument that binds the driver service to the device" do
            device = robot.device(device_m, using: driver_m, as: "dev")
            assert_same device, device.requirements.arguments[:driver_srv_dev]
        end
        it "validates the given service model against Device by default" do
            flexmock(device_m).should_receive(:<).with(Syskit::Device).and_return(false).once
            assert_raises(ArgumentError) do
                robot.device(device_m, using: driver_m, as: "dev")
            end
        end
        it "validates the given service model using the :expected_model option" do
            expected = flexmock
            flexmock(device_m).should_receive(:<).with(expected).and_return(false).once
            assert_raises(ArgumentError) do
                robot.device(device_m, using: driver_m, as: "dev", expected_model: expected)
            end
        end
        it "creates an object of the type given to its :class option" do
            klass = flexmock
            klass.should_receive(:new).once.and_return(obj = flexmock(doc: nil))
            assert_same obj, robot.device(device_m, using: driver_m, as: "dev", class: klass)
        end
        it "raises if no name has been given" do
            assert_raises(ArgumentError) { robot.device device_m, using: driver_m }
        end
        it "raises if a device with the given name already exists" do
            robot.devices["dev"] = Object.new
            assert_raises(ArgumentError) do
                robot.device device_m, as: "dev"
            end
        end
        it "resolves the actual driver service and gives it to the device object" do
            task_m = Syskit::TaskContext.new_submodel
            task_m.driver_for device_m, as: "drv"
            dev = robot.device(device_m, using: task_m, as: "dev")
            assert_equal task_m.drv_srv, dev.driver_model
        end
        it "registers all the slaves from the driver service" do
            task_m = Syskit::TaskContext.new_submodel
            task_m.driver_for device_m, as: "drv"
            task_m.provides Syskit::DataService.new_submodel, as: "slave", slave_of: "drv"
            master = robot.device device_m, using: task_m, as: "dev"
            assert(slave = robot.devices["dev.slave"])
            assert_same master, slave.master_device
        end

        it "invalidates the dependency injection cache" do
            flexmock(robot).should_receive(:invalidate_dependency_injection).at_least.once
            robot.device device_m, as: "test"
        end

        it "auto-discovers documentation by parsing a documentation block" do
            flexmock(Roby.app).should_receive(:app_file?).and_return(true)
            # The documentation
            device = robot.device device_m, as: "test"
            assert_equal "The documentation", device.doc
        end

        it "accepts being passed the documentation string expicitely" do
            # A documentation string that should be ignored
            device = robot.device device_m, as: "test", doc: "the documentation"
            assert_equal "the documentation", device.doc
        end
    end
end
