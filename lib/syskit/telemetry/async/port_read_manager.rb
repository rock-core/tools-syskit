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
                        Concurrent::ThreadPoolExecutor.new(
                            max_threads: CONNECTION_DEFAULT_THREADS
                        )
                end

                def self.default_disconnection_executor
                    @default_disconnection_executor ||=
                        Concurrent::ThreadPoolExecutor.new(
                            max_threads: DISCONNECTION_DEFAULT_THREADS
                        )
                end

                def self.default_read_executor
                    @default_read_executor ||=
                        Concurrent::ThreadPoolExecutor.new(
                            max_threads: READ_DEFAULT_THREADS
                        )
                end

                Callback = Struct.new(
                    :port, :callback, :period, :buffer_size,
                    :init, :needs_last_received_value, keyword_init: true
                ) do
                    def dispatch(value)
                        self.needs_last_received_value = false
                        callback.call(value)
                    end
                end

                Poller = Struct.new(
                    :port, :reader, :next_time, :period, :read_future,
                    :propagate_last_received_value, :last_value,
                    keyword_init: true
                ) do
                    def connected?
                        reader.connected?
                    end

                    def dispose
                        reader.dispose
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

                    def to_s(relative_to: PortReadManager.monotonic_time)
                        next_time_delta_ms = (next_time - relative_to) * 1000 if next_time

                        format(
                            "poller %<name>s: connected=%<connected>s " \
                            "scheduled=%<scheduled>s " \
                            "next_time=%<next_time>.3f (in %<next_time_delta_ms>i ms)",
                            name: port.full_name,
                            next_time: next_time || 0,
                            next_time_delta_ms: next_time_delta_ms || 0,
                            connected: connected? ? "yes" : "no",
                            scheduled: read_future ? "yes" : "no"
                        )
                    end

                    def schedule_read_if_needed(now, executor)
                        return if next_time && next_time > now

                        self.read_future = reader.raw_read_new(executor)
                    end

                    def prepare_next_read(now)
                        self.next_time ||= now
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

                    def policy
                        reader&.policy
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
                def register_callback(port, callback, period:, buffer_size:, init: false)
                    callback = Callback.new(
                        port: port, callback: callback,
                        period: period, buffer_size: buffer_size, init: init,
                        needs_last_received_value: true
                    )

                    (@callbacks[port] ||= []) << callback
                    ensure_reader_uptodate(port)
                    propagate_last_received_value(port)
                    Roby.disposable do
                        deregister_callback(port, callback)
                    end
                end

                # Request that the last received value is sent to the callbacks
                def propagate_last_received_value(port)
                    find_poller_for_port(port)&.propagate_last_received_value = true
                end

                # @api private
                #
                # De-registers a callback
                #
                # This is not meant to be called directly. Use the disposable
                # returned by {#register_callback} instead.
                def deregister_callback(port, callback)
                    return unless (callbacks = @callbacks[port])

                    callbacks.delete(callback)
                    if callbacks.empty?
                        remove_poller(port)
                    else
                        ensure_reader_uptodate(port)
                    end
                end

                # Reconnect the reader for this port if needed
                #
                # The main reason is the modification of the buffer policy
                def ensure_reader_uptodate(port)
                    poller = find_poller_for_port(port) ||
                             Poller.new(port: port)

                    policy = required_policy_for(port)
                    if policy != poller.policy
                        poller.reader&.dispose
                        poller.reader = port.reader(
                            connect_on: @connection_executor,
                            disconnect_on: @disconnection_executor,
                            **policy
                        )
                    end

                    update_poller_period(poller)
                    @pollers[port] = poller
                end

                # @api private
                #
                # Remove the poller for a given port
                def remove_poller(port)
                    return unless (poller = @pollers.delete(port))

                    poller.dispose
                end

                def dispose
                    @pollers.each_value(&:dispose)
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

                        process_poller_state(p, now)
                    end
                end

                # @api private
                #
                # Helper for {#poll} to process a single poller
                def process_poller_state(poller, now)
                    unless poller.connected?
                        poller.reset_read_tracking
                        return
                    end

                    if poller.propagate_last_received_value && poller.last_value &&
                       !poller.resolved_read?
                        dispatch_last_received_value(poller)
                    end

                    if !poller.scheduled_read?
                        poller.schedule_read_if_needed(now, @read_executor)
                    elsif poller.resolved_read?
                        dispatch_read_result(poller)
                        poller.prepare_next_read(now)
                    end
                end

                # Time in seconds returned by CLOCK_MONOTONIC
                def monotonic_time
                    self.class.monotonic_time
                end

                # Time in seconds returned by CLOCK_MONOTONIC
                def self.monotonic_time
                    Process.clock_gettime(Process::CLOCK_MONOTONIC)
                end

                # Send read data to registered callbacks
                def dispatch_read_result(poller)
                    fulfilled, value, reason = poller.result
                    if fulfilled
                        @callbacks[poller.port].each { |c| c.dispatch(value) }
                        poller.last_value = value
                        poller.propagate_last_received_value = false
                    else
                        warn "failed to read #{poller.port}: #{reason}"
                    end
                end

                # Send last received value to the callbacks that require it
                def dispatch_last_received_value(poller)
                    @callbacks[poller.port].each do |c|
                        c.dispatch(poller.last_value)
                    end
                    poller.propagate_last_received_value = false
                end

                # Return the buffer size needed by all callbacks of a port, in aggregate
                #
                # @return [Integer]
                def required_policy_for(port)
                    return unless (callbacks = @callbacks[port])

                    buffer_size = callbacks.map { _1.buffer_size }.max
                    init = callbacks.map { _1.init }.inject(&:|)
                    { type: :circular_buffer, size: buffer_size, init: init, pull: true }
                end
            end
        end
    end
end
