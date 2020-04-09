# frozen_string_literal: true

module Syskit
    # Namespace containing all the system management at runtime (propagation of
    # states, triggering of connection updates, ...)
    module Runtime
        extend Logger::Hierarchy
    end
end

require "syskit/runtime/apply_requirement_modifications"
require "syskit/runtime/exceptions"
require "syskit/runtime/connection_management"
require "syskit/runtime/update_deployment_states"
require "syskit/runtime/update_task_states"
