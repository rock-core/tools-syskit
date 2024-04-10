# frozen_string_literal: true

require "syskit/telemetry/agent/agent_services_pb"

module Syskit
    module Telemetry
        module Agent
            # Client for the telemetry agent
            #
            # This class is the low-ish level API for the telemetry agent, allowing
            # to interact with a remote set of Rock components through a single GRPC
            # API
            #
            # This API is built around a single data channel through which the agent's
            # server will send data samples. Which data streams must be monitored and
            # transferred is configured through the monitor_* methods
            # (e.g. {#monitor_port})
            #
            # The samples themselves are received by a block given to
            # {#create_data_channel}. This block is called in a separate thread, use
            # a Queue to transfer to a main thread if necessary.
            class Client < Grpc::Server::Stub
                # Add a single port to the monitored ports
                def monitor_port(task_name, port_name, period:, type: :data, size: 1)
                    grpc_type = GRPC_BUFFER_TYPE_FROM_SYMBOL.fetch(type)
                    monitor = Grpc::PortMonitor.new(
                        task_name: task_name, port_name: port_name, period: period,
                        policy: Grpc::BufferPolicy.new(type: grpc_type, size: size)
                    )
                    data_streams = port_monitoring_start(
                        Grpc::PortMonitors.new(monitors: [monitor])
                    )
                    data_stream = data_streams.streams.first
                    disposable = Roby.disposable do
                        port_monitoring_stop(
                            Grpc::PortMonitorIDs.new(ids: [data_stream.id])
                        )
                    end

                    [data_stream.id, disposable]
                end

                GRPC_BUFFER_TYPE_FROM_SYMBOL = {
                    data: Grpc::BufferType::DATA,
                    buffer: Grpc::BufferType::BUFFER_DROP_OLD,
                    ring_buffer: Grpc::BufferType::BUFFER_DROP_NEW
                }.freeze
            end
        end
    end
end
