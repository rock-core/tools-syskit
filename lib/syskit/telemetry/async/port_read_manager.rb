# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # @api private
            #
            # Central class that manages data readers for ports
            class PortReadManager
                def initialize(
                    connection_executor: self.class.default_connection_executor,
                    disconnection_executor: self.class.default_disconnection_executor,
                    read_executor: self.class.default_read_executor
                )
                    @callbacks = {}
                    @pollers = {}

                    @connection_executor = connection_executor
                    @disconnection_executor = disconnection_executor
                    @read_executor = read_executor
                end

                CONNECTION_DEFAULT_THREADS = 20
                DISCONNECTION_DEFAULT_THREADS = 20
                READ_DEFAULT_THREADS = 5

                def self.default_connection_executor
                    @default_connection_executor ||=
                        Concurrent::CachedThreadPool.new(
                            max_threads: CONNECTION_DEFAULT_THREADS
                        )
                end

                def self.default_disconnection_executor
                    @default_disconnection_executor ||=
                        Concurrent::CachedThreadPool.new(
                            max_threads: DISCONNECTION_DEFAULT_THREADS
                        )
                end

                def self.default_read_executor
                    @default_read_executor ||=
                        Concurrent::CachedThreadPool.new(
                            max_threads: READ_DEFAULT_THREADS
                        )
                end

                Callback = Struct.new(
                    :port, :callback, :period, :buffer_size, keyword_init: true
                ) do
                    def dispatch(value)
                        callback.call(value)
                    end
                end

                Poller = Struct.new(
                    :port, :reader, :next_time, :period, :read_future,
                    keyword_init: true
                ) do
                    def connected?
                        reader.connected?
                    end

                    def poll
                        reader.poll
                    end

                    def scheduled_read?
                        read_future
                    end

                    def result
                        read_future&.result
                    end

                    def schedule_read_if_needed(now, executor)
                        self.next_time ||= now
                        return unless self.next_time <= now

                        self.read_future = reader.raw_read_new(executor)
                    end

                    def prepare_next_read(now)
                        delta_in_periods = ((now - next_time) / period).ceil
                        # delta_in_periods == 0 should be impossible.
                        # But, you know, little cost
                        self.next_time += [delta_in_periods, 1].max * period
                        self.read_future = nil
                    end

                    def resolved_read?
                        read_future&.resolved?
                    end

                    def reset_read_tracking
                        self.read_future = nil
                        self.next_time = nil
                    end

                    def buffer_size
                        reader&.buffer_size
                    end
                end

                # Register a callback for data from a port
                #
                # @param [Async::OutputPort] port the port whose data is needed
                # @param [#call] callback the object that will receive data when
                #   available
                # @param [Numeric] period reading period in seconds
                # @param [Integer] buffer_size the size of the sample buffer requested
                #   by the callback. The actual buffer will be of *at least* that many
                #   samples.
                def register_callback(port, callback, period:, buffer_size:)
                    callback = Callback.new(
                        port: port, callback: callback,
                        period: period, buffer_size: buffer_size
                    )

                    (@callbacks[port] ||= []) << callback
                    ensure_reader_uptodate(port)
                end

                # Reconnect the reader for this port if needed
                #
                # The main reason is the modification of the buffer policy
                def ensure_reader_uptodate(port)
                    poller = find_poller_for_port(port) ||
                             Poller.new(port: port)

                    buffer_size = required_buffer_size_for(port)
                    if buffer_size != poller.buffer_size
                        poller.reader&.dispose
                        poller.reader = port.reader(
                            connect_on: @connection_executor,
                            disconnect_on: @disconnection_executor,
                            type: :circular_buffer, pull: true, size: buffer_size
                        )
                    end

                    update_poller_period(poller)
                    @pollers[port] = poller
                end

                def dispose
                    @pollers.each_value do |p|
                        p.reader.dispose
                    end
                    @pollers = {}
                end

                # Whether we are currently polling the given port
                def polling?(port)
                    @pollers.key?(port)
                end

                # Update a poller's period to match the callbacks currently listening
                # to it
                def update_poller_period(poller)
                    poller.period = @callbacks[poller.port].map(&:period).min
                end

                # Return the Reader for the given port
                #
                # @return [Reader,nil]
                def find_poller_for_port(port)
                    @pollers[port]
                end

                # Method called regularly to update the asynchronous class state
                def poll
                    now = monotonic_time
                    @pollers.each_value do |p|
                        p.poll

                        if !p.connected?
                            p.reset_read_tracking
                        elsif !p.scheduled_read?
                            p.schedule_read_if_needed(now, @read_executor)
                        elsif p.resolved_read?
                            dispatch_read_result(p)
                            p.prepare_next_read(now)
                        end
                    end
                end

                # Time in seconds returned by CLOCK_MONOTONIC
                def monotonic_time
                    Process.clock_gettime(Process::CLOCK_MONOTONIC)
                end

                # Send read data to registered callbacks
                def dispatch_read_result(poller)
                    fulfilled, value, reason = poller.result
                    if fulfilled
                        @callbacks[poller.port].each { |c| c.dispatch(value) }
                    else
                        warn "failed to read #{poller.port}: #{reason}"
                    end
                end

                # Return the buffer size needed by all callbacks of a port, in aggregate
                #
                # @return [Integer]
                def required_buffer_size_for(port)
                    return unless (callbacks = @callbacks[port])

                    callbacks.map { _1.buffer_size }.max
                end
            end
        end
    end
end
