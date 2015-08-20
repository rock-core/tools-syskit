require 'syskit/test/self'

require './test/robot/test_device'
require './test/robot/test_robot_definition'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
