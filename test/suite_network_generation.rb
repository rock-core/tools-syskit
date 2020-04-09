# frozen_string_literal: true

require "syskit/test/self"

require "./test/network_generation/test_async"
require "./test/network_generation/test_system_network_deployer"
require "./test/network_generation/test_system_network_generator"
require "./test/network_generation/test_engine"
require "./test/network_generation/test_merge_solver"
require "./test/network_generation/test_logger"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
