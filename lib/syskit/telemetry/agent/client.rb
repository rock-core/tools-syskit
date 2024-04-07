# frozen_string_literal: true

require "syskit/telemetry/agent/agent_services_pb"

module Syskit
    module Telemetry
        module Agent
            class Client < Grpc::Server::Stub
            end
        end
    end
end
