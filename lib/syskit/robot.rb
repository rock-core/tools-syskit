# frozen_string_literal: true

module Syskit
    # Namespace for all objects used to describe a robot
    #
    # The main class is Robot::RobotDefinition. The robot definition for a
    # complete Roby application is accessible with Conf.robot
    module Robot
    end
end

require "syskit/robot/device_instance"
require "syskit/robot/master_device_instance"
require "syskit/robot/slave_device_instance"
require "syskit/robot/communication_bus"
require "syskit/robot/robot_definition"
