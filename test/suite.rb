require 'syskit/test/self'

if ENV['TEST_ENABLE_COVERAGE'] == '1' || rand > 0.5
    null_io = File.open('/dev/null', 'w')
    current_formatter = Syskit.logger.formatter
    Syskit.warn "running tests with logger in DEBUG mode"
    Syskit.logger = Logger.new(null_io)
    Syskit.logger.level = Logger::DEBUG
    Syskit.logger.formatter = current_formatter
else
    Syskit.warn "running tests with logger in FATAL mode"
    Syskit.logger.level = Logger::FATAL + 1
end

require './test/suite_models'
require './test/suite_robot'
require './test/suite_roby_app'
require './test/suite_network_generation'
require './test/suite_actions'
require './test/suite_runtime'
require './test/suite_coordination'
require './test/suite_droby'

require './test/test_abstract_placeholders'
require './test/test_bound_data_service'
require './test/test_port'
require './test/test_data_service'
require './test/test_component'
require './test/test_composition'
require './test/test_task_context'
require './test/test_deployment'
require './test/test_instance_requirements'
require './test/test_instance_selection'
require './test/test_connection_graphs'
require './test/test_connection_graph'
require './test/test_data_flow'
require './test/test_dependency_injection'
require './test/test_dependency_injection_context'
require './test/test_instance_requirements_task'
require './test/test_shell_interface'

require './test/test_exceptions'

