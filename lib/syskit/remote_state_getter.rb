# frozen_string_literal: true

module Syskit
    # @api private
    #
    # Adapter that reads the synchronous state of a remote node asynchronously
    #
    # It is started in a paused state, waiting for {#resume} to be called to
    # start polling the remote state
    class RemoteStateGetter
        # The task we're polling
        attr_reader :orocos_task
        # The polling period in seconds
        attr_reader :period
        # The last read state
        attr_reader :last_read_state

        # Exception raised if the current getter's state is invalid for an operation
        class InvalidRuntimeStateError < RuntimeError; end
        # @deprecated
        class NotYetStarted < InvalidRuntimeStateError; end

        def initialize(orocos_task, initial_state: nil, period: 0.02)
            @orocos_task = orocos_task
            @period = period
            @exit_condition = Concurrent::Event.new
            @run_event = Concurrent::Event.new
            @current_state = Concurrent::Atom.new(initial_state)
            @state_queue = Queue.new
            @poll_thread_error = Concurrent::Atom.new(nil)
            @last_read_state = nil
            @state_queue.push(initial_state) if initial_state

            @wait_sync = Mutex.new
            @wait_signal = ConditionVariable.new

            @period = period
            @exit_condition.reset
        end

        def start
            @wait_sync.synchronize do
                @cycle_start_index = 0
                @cycle_end_index = 0
            end

            @poll_thread = Thread.new do
                poll_loop
            end
            resume
        end

        def started?
            @poll_thread
        end

        # The internal polling loop
        def poll_loop
            last_state = nil

            until @exit_condition.set?
                @wait_sync.synchronize { @cycle_start_index += 1 }

                time = Time.now
                state = orocos_task.read_toplevel_state
                if (state != last_state) || !@current_state.value
                    @current_state.reset(state)
                    @state_queue.push(state)
                    last_state = state
                end

                @wait_sync.synchronize do
                    @cycle_end_index += 1
                    @wait_signal.broadcast
                end

                spent = (Time.now - time)
                if spent < period
                    @exit_condition.wait(period - spent)
                end
                @run_event.wait
            end
        rescue Exception => e
            @poll_thread_error.reset(e)
        ensure
            @wait_sync.synchronize do
                @exit_condition.set
                @wait_signal.broadcast
            end
        end

        # @api private
        #
        # Raise if self is not started
        def validate_thread_running
            return if @poll_thread

            raise NotYetStarted,
                  "called an operation on a RemoteStateGetter that is not running. "\
                  "call #start first"
        end

        # @api private
        #
        # Validate that the poll thread is in a state that won't block {#wait} forever
        def validate_can_wait
            validate_thread_running

            if !@run_event.set?
                raise InvalidRuntimeStateError,
                      "error calling or within #wait: #{self} is paused"
            elsif (error = @poll_thread_error.value)
                raise error,
                      "error calling or within #wait: #{self}'s poll thread quit "\
                      "with #{error.message}", (error.backtrace + caller)
            elsif @exit_condition.set?
                raise InvalidRuntimeStateError,
                      "error calling or within #wait: #{self} is quitting"
            end
        end

        # Wait for the current state to be read and return it
        def wait
            @wait_sync.synchronize do
                start_cycle = @cycle_start_index

                while @cycle_end_index <= start_cycle
                    validate_can_wait

                    @wait_signal.wait(@wait_sync)
                end
            end

            @current_state.value
        end

        # Whether the state reader has read at least one state
        def ready?
            @last_read_state || !@state_queue.empty?
        end

        # Read either a new or the last read state
        def read
            read_new || @last_read_state
        end

        # Read a new state change
        def read_new(_sample = nil)
            if (new_state = @state_queue.pop(true))
                @last_read_state = new_state
            end
        rescue ThreadError
        end

        # Read and return whether there was a new sample
        def read_with_result(_sample, copy_old_data = false)
            if (new_state = @state_queue.pop(true))
                @last_read_state = new_state
                [true, @last_read_state]
            else
                [false, (@last_read_state if copy_old_data)]
            end
        rescue ThreadError
        end

        def clear
            @state_queue.clear
            @current_state.reset(nil)
            @last_read_state = nil
        end

        # Whether the polling thread is alive
        def connected?
            @poll_thread && !@exit_condition.set?
        end

        # Pause polling until {#resume} or {#disconnect} are called
        #
        # The poll thread is not yet asleep right after this call. The only
        # guarantee is that it will stop polling after it is done with the
        # current state refresh
        def pause
            validate_thread_running

            @wait_sync.synchronize do
                if @exit_condition.set?
                    raise InvalidRuntimeStateError,
                          "cannot call #pause, #{self} is quitting"
                end

                @run_event.reset
                @wait_signal.broadcast
            end
        end

        # @api private
        #
        # Whether the internal polling thread is asleep
        def asleep?
            @poll_thread.status == "sleep"
        end

        # Resume polling after a {#pause}
        #
        # It is safe to call even if the polling is currently active
        def resume
            validate_thread_running

            @run_event.set
        end

        # Either {#start} the getter if it is not running yet, or resume it if
        # it is paused
        def resume_or_start
            if @poll_thread
                resume
            else
                start
            end
        end

        # Stop polling completely
        #
        # After calling {#disconnect}, the reader cannot be connected again. Use
        # {#pause} and {#resume} to temporarily stop polling
        def disconnect
            # This order ensures that {#poll_thread} will quit immediately if it
            # was paused
            @wait_sync.synchronize do
                @exit_condition.set
                @run_event.set
            end
        end

        # Wait for the poll thread to finish after a {#disconnect}
        def join
            @poll_thread&.join
        end
    end
end
