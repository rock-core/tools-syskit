# frozen_string_literal: true

require "syskit/roby_app/remote_processes/server"
require "syskit/roby_app/remote_processes/client"
require "syskit/roby_app/remote_processes/loader"
require "syskit/roby_app/remote_processes/log_upload_state"
require "syskit/roby_app/remote_processes/process"
require "syskit/roby_app/remote_processes/protocol"

module Syskit
    module RobyApp
        # Implementation of Syskit's remote process server and client
        module RemoteProcesses
            extend Logger::Hierarchy
            extend Logger::Forward
        end
    end
end
