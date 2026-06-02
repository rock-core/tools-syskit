# frozen_string_literal: true

require "syskit/telemetry/async/main_thread_restrictions"

require "syskit/telemetry/async/remote_system"
require "syskit/telemetry/async/name_service"
require "syskit/telemetry/async/task_context"
require "syskit/telemetry/async/interface_object"
require "syskit/telemetry/async/readable_interface_object"
require "syskit/telemetry/async/listener"
require "syskit/telemetry/async/attribute"
require "syskit/telemetry/async/property"
require "syskit/telemetry/async/input_port"
require "syskit/telemetry/async/output_port"
require "syskit/telemetry/async/output_port_subfield"
require "syskit/telemetry/async/output_reader"
require "syskit/telemetry/async/port_read_manager"

module Syskit
    module Telemetry
        # Asynchronous access to remote state
        module Async
        end
    end
end
