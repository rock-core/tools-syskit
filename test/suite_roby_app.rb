require 'syskit/test/self'

require './test/roby_app/test_plugin'
require './test/roby_app/test_configuration'
require './test/roby_app/test_unmanaged_tasks'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
