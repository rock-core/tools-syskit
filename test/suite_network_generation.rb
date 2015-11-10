require 'syskit/test/self'

require './test/network_generation/test_engine'
require './test/network_generation/test_merge_solver'
require './test/network_generation/test_logger'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG

