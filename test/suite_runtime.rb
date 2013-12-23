if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '1'
end
require 'syskit/test/self'

require './test/runtime/test_connection_management'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
