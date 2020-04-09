# frozen_string_literal: true

require "syskit/test/self"

require "./test/runtime/test_apply_requirement_modifications"
require "./test/runtime/test_connection_management"
require "./test/runtime/test_update_deployment_state"
require "./test/runtime/test_update_task_states"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
