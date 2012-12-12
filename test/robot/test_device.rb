require 'syskit'
require 'syskit/test'

describe Syskit::Robot::MasterDeviceInstance do
    include Syskit::SelfTest

    describe "combus attachment" do
        attr_reader :combus_m, :device_m, :driver_m
        attr_reader :robot, :bus, :dev
        before do
            @device_m = Syskit::Device.new_submodel
            @combus_m = Syskit::ComBus.new_submodel :message_type => "/double"
            @robot = Syskit::Robot::RobotDefinition.new
            combus_driver_m = Syskit::TaskContext.new_submodel do
                dynamic_input_port /^w\w+$/, "/double"
                dynamic_output_port /^\w+$/, "/double"
            end
            combus_driver_m.provides combus_m, :as => 'combus_driver'
            @bus = robot.com_bus combus_m, :as => 'bus0'
            @driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for device_m, :as => 'dev_driver'
            @dev = robot.device device_m, :as => 'dev0'
        end

        describe "#attach_to" do
            it "should find combus_in_srv automatically if the task provides the requested service" do
                driver_m.orogen_model.input_port 'combus_in', '/double'
                driver_m.provides combus_m.client_in_srv, :as => 'combus_in'
                dev.attach_to(bus)

                assert_equal dev.combus_in_srv, driver_m.combus_in_srv
            end
            it "should raise if the driver has no I/O available for the combus" do
                assert_raises(ArgumentError) { dev.attach_to(bus) }
            end
        end

        describe "#attached_to?" do
            before do
                driver_m.orogen_model.input_port 'combus_in', '/double'
                driver_m.provides combus_m.client_in_srv, :as => 'combus_in'
            end

            it "should return true if the device is attached to a combus with the given name" do
                dev.attach_to(bus)
                assert dev.attached_to?('bus0')
            end
            it "should return true if the device is attached to the given combus" do
                dev.attach_to(bus)
                assert dev.attached_to?(bus)
            end
            it "should return false if the device is not attached to a combus with the given name" do
                assert !dev.attached_to?('bus0')
            end
            it "should return true if the device is not attached to the given combus" do
                assert !dev.attached_to?(bus)
            end
        end
    end
end
