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
                def initialize(host, certificate)
                    super
                    @registry = Typelib::Registry.new
                end

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

                def read_property(task_name, property_name)
                    grpc_property = Grpc::Property.new(
                        task_name: task_name, property_name: property_name
                    )

                    grpc_values = read_properties(
                        Grpc::Properties.new(properties: [grpc_property])
                    )
                    resolve_property_values(grpc_values.values).first
                end

                def resolve_property_values(grpc_values)
                    types = resolve_types(grpc_values.map(&:type_name))
                    grpc_values.zip(types).map do |v, t|
                        t.from_buffer(v.data)
                    end
                end

                def resolve_types(type_names)
                    types = type_names.map do |name|
                        [name, @registry.get(name)]
                    rescue Typelib::NotFound
                        [name, nil]
                    end

                    needs_resolution = types.find_all { |_, t| !t }.map(&:first)
                    resolved_types = resolve_types_from_remote(needs_resolution)
                    resolved_types_by_name = Hash[
                        resolved_types.map { |t| [t.name, t] }
                    ]
                    types.map { |name, t| t || resolved_types_by_name[name] }
                end

                def resolve_types_from_remote(type_names)
                    return [] if type_names.empty?

                    grpc_type_names = Grpc::TypeNames.new(names: type_names)
                    grpc_type_definitions = type_definitions(grpc_type_names)
                    merge_type_definitions(
                        type_names.zip(grpc_type_definitions.definitions)
                    )
                end

                def merge_type_definitions(type_definitions)
                    type_definitions.map do |name, grpc_t|
                        @registry.merge_xml(grpc_t)
                        @registry.get(name)
                    end
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
