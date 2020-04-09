# frozen_string_literal: true

require "syskit/test/self"
require "./test/ros/test_task_context"

Syskit.logger = Logger.new(File.open("/dev/null", "w"))
Syskit.logger.level = Logger::DEBUG
