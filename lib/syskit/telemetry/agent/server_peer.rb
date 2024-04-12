# frozen_string_literal: true

module Syskit
    module Telemetry
        module Agent
            # Handling of a single peer server-side
            class ServerPeer
                def initialize(peer_id, name_service)
                    @peer_id = peer_id
                    @id = Concurrent::AtomicFixnum.new
                    @readers_mu = Mutex.new
                    @readers = {}
                    @name_service = name_service
                end

                # Cleans up resources for this peer
                def dispose
                    readers = @readers_mu.synchronize do
                        temp = @readers
                        @readers = {}
                        temp
                    end
                    readers.each_value(&:dispose)
                end

                def self.create_data_channel(server, call)
                    peer = server.register_peer(call.peer)
                    enum_for(:data_channel, peer, server, call)
                end

                # @api private
                #
                # Implementation of the enumerator needed by the GRPC streaming API
                def self.data_channel(peer, server, call)
                    until call.cancelled?
                        now = Time.now
                        next_deadline = peer.poll_subscribed_streams(now) do |id, sample|
                            yield Grpc::DataStreamValue.new(
                                id: id, data: sample.to_byte_array
                            )
                        end

                        if next_deadline
                            sleep(next_deadline - now)
                        else
                            sleep 1
                        end
                    end
                ensure
                    server.deregister_peer(call.peer)
                    peer.dispose
                end

                # @api private
                #
                # Read the subscribed streams that reached their deadline
                #
                # @param [Time] now the time used to determine whether the deadline
                #   is reached or not
                # @return [Time] the closest read deadline
                def poll_subscribed_streams(now)
                    samples = @readers_mu.synchronize do
                        @readers.map do |id, reader|
                            next unless reader.ready?(now)

                            s = reader.raw_read_new
                            reader.update_deadline(now)
                            [id, s] if s
                        end
                    end
                    samples.each { |id, s| yield(id, s) if id }

                    @readers_mu.synchronize do
                        @readers.each_value
                                .min(&:deadline)
                                &.deadline
                    end
                end

                # Start monitoring some ports
                #
                # The `id` field of the returned objects can be used to stop
                # monitoring the corresponding streams
                #
                # @param [Array<Grpc::PortMonitor>] monitors
                # @return [{ Integer => MonitoredReader }]
                def port_monitoring_start(monitors)
                    new_readers = create_monitored_readers(monitors)
                    @readers_mu.synchronize do
                        @readers.merge!(new_readers)
                    end
                    new_readers
                end

                # Stop monitoring some ports
                #
                # @param [Array<Integer>] ids the IDs of the port monitors to be
                #   cancelled, as returned by {#port_monitoring_start}
                # @return [Array<MonitoredReader>]
                def port_monitoring_stop(ids)
                    readers = @readers_mu.synchronize do
                        ids.map { |id| @readers.delete(id) }
                    end
                    readers.compact.each(&:dispose)
                end

                # @api private
                #
                # Create MonitoredReader objects for the given monitors
                #
                # @return [{ Integer => MonitoredReader }] the mapping of stream IDs to
                #   the created readers
                def create_monitored_readers(monitors)
                    monitors.each_with_object(new_readers = {}) do |monitor, readers|
                        id = @id.increment
                        readers[id] = create_monitored_reader(monitor)
                    end
                rescue RuntimeError
                    new_readers&.each_value(&:dispose)
                    raise
                end

                # @api private
                #
                # Create the MonitoredReader for the given monitoring spec
                def create_monitored_reader(monitor)
                    port = @name_service.get(monitor.task_name).port(monitor.port_name)
                    reader = port.reader(
                        type: GRPC_BUFFER_TYPE_TO_SYMBOL.fetch(monitor.policy.type),
                        size: monitor.policy.size || 0
                    )

                    MonitoredReader.new(
                        reader: reader, period: monitor.period, deadline: Time.now
                    )
                end

                MonitoredReader =
                    Struct.new(:reader, :period, :deadline, keyword_init: true) do
                        def raw_read_new
                            reader.raw_read_new
                        end

                        def ready?(now)
                            deadline < now
                        end

                        def update_deadline(now)
                            self.deadline += period until deadline > now
                            self.deadline
                        end

                        def disconnect
                            reader.disconnect
                        end

                        def dispose
                            disconnect
                        end
                    end

                GRPC_BUFFER_TYPE_TO_SYMBOL = {
                    DATA: :data,
                    BUFFER_DROP_OLD: :buffer,
                    BUFFER_DROP_NEW: :ring_buffer
                }.freeze
            end
        end
    end
end
