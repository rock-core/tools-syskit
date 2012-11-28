require './test_helper'
start_simple_cov 'suite'

require './models/test_bound_data_service'
require './models/test_component'
require './models/test_composition'
require './models/test_data_services'
require './models/test_task_context'

require './test_abstract_placeholders'
require './test_bound_data_service'
require './test_component'
require './test_composition'
require './test_task_context'
require './test_engine'
#require './test_instance_spec'
require './test_network_merge_solver'

Syskit.logger = Logger.new(File.open("/dev/null", 'w'))
Syskit.logger.level = Logger::DEBUG
