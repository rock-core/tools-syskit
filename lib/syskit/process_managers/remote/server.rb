# frozen_string_literal: true

require "socket"
require "fcntl"
require "net/ftp"
require "orocos"

require "concurrent/atomic/atomic_reference"

module Syskit
    module ProcessManagers
        module Remote
            # Implementation of the syskit process server
            module Server
                extend Logger::Root(self.class.to_s, Logger::INFO)
            end
        end
    end
end

require "syskit/process_managers/remote/protocol"
require "syskit/process_managers/remote/server/ftp_upload"
require "syskit/process_managers/remote/server/log_upload_state"
require "syskit/process_managers/remote/server/server"
