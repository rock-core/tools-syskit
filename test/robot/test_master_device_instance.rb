require 'syskit/test/self'

module Syskit
    module Robot
        describe MasterDeviceInstance do
            attr_reader :device, :device_m, :driver_m, :robot_m
            before do
                @device_m = Device.new_submodel
                @driver_m = TaskContext.new_submodel
                driver_m.driver_for device_m, as: 'dev'

                @robot_m = RobotDefinition.new
                @device = robot_m.device device_m, as: 'test', using: driver_m
            end

            describe "droby-marshalling" do
                it "is droby-compatible" do
                    transferred = assert_droby_compatible(device)
                    assert_equal 'test', transferred.name
                end

                it "does add the newly created device instance to a RobotDefinition object" do
                    transferred = assert_droby_compatible(device)
                    assert_kind_of RobotDefinition, transferred.robot
                    assert_same transferred, transferred.robot.find_device('test')
                end
            end

            describe "#==" do
                it "returns false for an object that is not a MasterDeviceInstance" do
                    refute(device == Object.new)
                end
                it "returns false if the robot object differs" do
                    other_robot_m = RobotDefinition.new
                    other_device = other_robot_m.device device_m, as: 'test', using: driver_m
                    refute(device == other_device)
                end
                it "returns false if the name differs" do
                    other_device = robot_m.device device_m, as: 'other_test', using: driver_m
                    refute(device == other_device)
                end
                it "returns if this is the device of a given name on the same robot object" do
                    assert(device == flexmock(kind_of?: true, robot: robot_m, name: device.name))
                end
            end
        end
    end
end

