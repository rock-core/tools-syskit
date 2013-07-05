if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '2'
end
require 'syskit/test'

require './test/coordination/test_data_monitoring_error'
require './test/coordination/test_data_monitoring_table'
require './test/coordination/test_data_monitor'
require './test/coordination/test_task_script'
require './test/coordination/test_fault_response_table_extension'
require './test/coordination/test_plan_extension'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
