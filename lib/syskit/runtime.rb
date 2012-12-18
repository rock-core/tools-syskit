module Syskit
    # Namespace containing all the system management at runtime (propagation of
    # states, triggering of connection updates, ...)
    module Runtime
        extend Logger::Hierarchy
    end
end

require 'syskit/runtime/apply_requirements_modifications'
require 'syskit/runtime/exceptions'
require 'syskit/runtime/runtime_connection_management'
require 'syskit/runtime/update_deployment_states'
require 'syskit/runtime/update_task_states'
