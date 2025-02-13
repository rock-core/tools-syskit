# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Holder for a resolved data reader
            class OutputReader
                # The async port this reader is connected to
                attr_reader :port

                # The policy hash used to create this reader
                attr_reader :policy

                def initialize(port, policy, connect_on:, disconnect_on:)
                    @port = port
                    @policy = policy.dup.freeze

                    @cancel_event = Concurrent::Promises.resolvable_event
                    @connection_future = nil
                    @last_read_future = Concurrent::Promises.fulfilled_future(nil)
                    @reader = Concurrent::AtomicReference.new(nil)

                    @connection_executor = connect_on
                    @disconnection_executor = disconnect_on

                    @reachability_listener = port.on_reachable do |raw_port|
                        connect(raw_port, policy)
                    end

                    @unreachability_listener = port.on_unreachable do
                        disconnect_on_unreachability
                    end
                end

                def raw_reader
                    @reader.get
                end

                def connected?
                    @reader.get
                end

                def poll
                    resolve_connection unless @reader.get
                end

                def resolve_connection
                    return unless @connection_future&.resolved?

                    fulfilled, result, reason = @connection_future.result
                    if fulfilled
                        @reader.set(result)
                    else
                        warn "failed to create reader on #{@port}: #{reason}"
                    end

                    @connection_future = nil
                end

                def raw_read_with_result(executor, sample = nil, copy_old_data = true) # rubocop:disable Style/OptionalBooleanParameter
                    @last_read_future = @last_read_future.chain_on(executor) do
                        @reader.get&.raw_read_with_result(sample, copy_old_data)
                    end
                end

                def raw_read(executor, sample = nil, copy_old_data: true)
                    raw_read_with_result(executor, sample, copy_old_data)
                        .then do |_, read_sample|
                            read_sample
                        end
                end

                def raw_read_new(executor, sample = nil)
                    raw_read_with_result(executor, sample, false)
                        .then do |result, read_sample|
                            read_sample if result == Orocos::NEW_DATA
                        end
                end

                # @api private
                #
                # Connect to the actual port
                def connect(raw_port, policy)
                    if @reader.get
                        raise StateError,
                              "#connect called on an already connected reader"
                    end

                    cancel_event = @cancel_event
                    future = Concurrent::Promises.future_on(@connection_executor) do
                        raw_port.reader(**policy) unless cancel_event.resolved?
                    end
                    @connection_future = future
                end

                # @api private
                #
                # Internal disconnection method, leaving the reader reconnect when the
                # port is reachable again
                def disconnect_on_unreachability
                    @cancel_event.resolve
                    @cancel_event = Concurrent::Promises.resolvable_event

                    disconnect_future =
                        (@connection_future || @last_read_future)
                        .then_on(@disconnection_executor, @reader.get) do |_, reader|
                            reader&.disconnect
                        end

                    @reader.set(nil)
                    @connection_future = nil
                    @last_read_future = Concurrent::Promises.fulfilled_future(nil)
                    disconnect_future
                end

                # Disconnect from the remote port
                #
                # Note that this discards any data that is still being read. The
                # port will automatically reconnect
                def disconnect
                    dispose
                end

                # Disconnect and disable this reader
                def dispose
                    @reachability_listener.dispose
                    @unreachability_listener.dispose
                    disconnect_on_unreachability
                end

                def disposed?
                    @reachability_listener.disposed?
                end
            end
        end
    end
end
