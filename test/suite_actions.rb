# frozen_string_literal: true

require "syskit/test/self"
require "./test/actions/test_interface_model_extension"
require "./test/actions/test_profile"
require "./test/actions/test_action_model"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
