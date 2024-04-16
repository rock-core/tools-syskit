# frozen_string_literal: true

require "syskit/telemetry/agent/agent_services_pb"
require "syskit/telemetry/agent/server_peer"

module Syskit
    module Telemetry
        module Agent
            class DuplicateDataStream < RuntimeError; end
            class PeerNotConnected < RuntimeError; end

            # Server for the telemetry agent
            #
            # This class implements the server-side functionality for the agent
            class Server < Grpc::Server::Service
                def initialize(name_service)
                    @name_service = name_service
                    @peers_mu = Mutex.new
                    @peers = {}
                end

                def data(_void, call)
                    ServerPeer.create_data_channel(self, call)
                end

                def port_monitoring_start(port_monitors, call)
                    new_readers = peer(call.peer) do |c|
                        c.port_monitoring_start(port_monitors.monitors)
                    end

                    pb_streams = new_readers.map do |id, r|
                        Grpc::DataStream.new(id: id, typelib_xml: r.reader.type.to_xml)
                    end
                    Grpc::DataStreams.new(streams: pb_streams)
                end

                def port_monitoring_stop(port_monitor_ids, call)
                    peer(call.peer).port_monitoring_stop(port_monitor_ids.ids)
                    Grpc::Void.new
                end

                def read_properties(properties, _call)
                    values = read_properties_raw(properties.properties)

                    grpc_values = values.map do |v|
                        Grpc::PropertyValue.new(
                            type_name: v.class.name,
                            data: v.to_byte_array
                        )
                    end
                    Grpc::PropertyValues.new(values: grpc_values)
                end

                def read_properties_raw(properties)
                    properties.map do |p|
                        @name_service.get(p.task_name).property(p.property_name).raw_read
                    end
                end

                def type_definitions(names, _call)
                    types = names.names.map do |n|
                        Roby.app.default_loader.resolve_type(n)
                    end
                    Grpc::TypeDefinitions.new(definitions: types.map(&:to_xml))
                end

                def dispose
                    peers = @peers_mu.synchronize do
                        temp = @peers
                        @peers = {}
                        temp
                    end

                    peers.each_value(&:dispose)
                end

                # @api private
                #
                # Create and register a {ServerPeer} for the given peer ID
                #
                # @return [ServerPeer]
                # @raise DuplicateDataStream if the peer is already registered
                def register_peer(peer_id)
                    @peers_mu.synchronize do
                        if @peers[peer_id]
                            raise DuplicateDataStream,
                                  "there is already a data stream for peer #{peer_id}"
                        end

                        @peers[peer_id] = ServerPeer.new(peer_id, @name_service)
                    end
                end

                def deregister_peer(peer_id)
                    peer = @peers_mu.synchronize do
                        @peers.delete(peer_id)
                    end
                    peer&.dispose
                end

                def peer(peer_id)
                    @peers_mu.synchronize do
                        unless (peer = @peers[peer_id])
                            raise PeerNotConnected,
                                  "no data channel established for peer #{peer_id}"
                        end

                        if block_given?
                            yield(peer)
                        else
                            peer
                        end
                    end
                end
            end
        end
    end
end
