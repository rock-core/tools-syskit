# frozen_string_literal: true

require "syskit/test/self"

require "./test/models/test_configured_deployment"
require "./test/models/test_deployment_group"
require "./test/models/test_base"
require "./test/models/test_port"
require "./test/models/test_bound_data_service"
require "./test/models/test_component"
require "./test/models/test_composition"
require "./test/models/test_composition_child"
require "./test/models/test_composition_specialization"
require "./test/models/test_data_services"
require "./test/models/test_deployment"
require "./test/models/test_specialization_manager"
require "./test/models/test_task_context"
require "./test/models/test_faceted_access"
require "./test/models/test_placeholder"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
