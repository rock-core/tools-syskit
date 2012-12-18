if !ENV['SYSKIT_ENABLE_COVERAGE']
    ENV['SYSKIT_ENABLE_COVERAGE'] = '1'
end
require 'syskit/test'

require './test/suite_models'
require './test/suite_robot'
require './test/suite_network_generation'

require './test/test_abstract_placeholders'
require './test/test_bound_data_service'
require './test/test_port'
require './test/test_data_service'
require './test/test_component'
require './test/test_composition'
require './test/test_task_context'
require './test/test_deployment'
require './test/test_instance_requirements'
require './test/test_connection_graphs'
require './test/test_dependency_injection'
require './test/test_instance_requirements_task'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG

# OK Coverage for now:
#   models/base
#   base
#   models/data_service
#   models/deployment
#   models/component
