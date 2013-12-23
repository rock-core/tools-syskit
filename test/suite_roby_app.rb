if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '1'
end
require 'syskit/test/self'

require './test/roby_app/test_plugin'
require './test/roby_app/test_configuration'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
