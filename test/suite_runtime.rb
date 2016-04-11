require 'syskit/test/self'

require './test/runtime/test_connection_management'
require './test/runtime/test_update_deployment_state'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
