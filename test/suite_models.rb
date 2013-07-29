if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '1'
end
require 'syskit/test'

require './test/models/test_base'
require './test/models/test_port'
require './test/models/test_bound_data_service'
require './test/models/test_component'
require './test/models/test_composition'
require './test/models/test_composition_child'
require './test/models/test_composition_specialization'
require './test/models/test_data_services'
require './test/models/test_deployment'
require './test/models/test_specialization_manager'
require './test/models/test_task_context'
require './test/models/test_faceted_access'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
