# frozen_string_literal: true

require "syskit/telemetry/agent/agent_services_pb"

module Syskit
    module Telemetry
        module Agent
            class Server < Grpc::Server::Service
            end
        end
    end
end
