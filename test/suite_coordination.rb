# frozen_string_literal: true

require "syskit/test/self"

require "./test/coordination/test_data_monitoring_error"
require "./test/coordination/test_data_monitoring_table"
require "./test/coordination/test_data_monitor"
require "./test/coordination/test_task_script"
require "./test/coordination/test_fault_response_table_extension"
require "./test/coordination/test_plan_extension"
require "./test/coordination/test_models_task_extension"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
