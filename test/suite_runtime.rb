require 'syskit/test/self'

require './test/runtime/test_connection_management'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
