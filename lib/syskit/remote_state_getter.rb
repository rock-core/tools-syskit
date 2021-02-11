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
        # The condition used to make the polling thread quit
        attr_reader :exit_condition
        # The thread that polls #rtt_state
        attr_reader :poll_thread
        # The exception that terminated {#poll_thread}
        attr_reader :poll_thread_error
        # The queue of values read by #poll_thread
        attr_reader :state_queue
        # Holder for the latch that is used by {#wait} for synchronization
        attr_reader :sync_latch
        # The newest known state
        attr_reader :current_state
        # The last read state
        attr_reader :last_read_state
        # Control for pause/resume
        attr_reader :run_event
        # To avoid deadlocking in {#wait} if the thread quits
        attr_reader :poll_thread_exit_sync

        # Exception raised when an operation that requires the getter to be
        # started is called
        class NotYetStarted < RuntimeError; end

        def initialize(orocos_task, initial_state: nil, period: 0.02)
            @orocos_task = orocos_task
            @period = period
            @exit_condition = Concurrent::Event.new
            @run_event = Concurrent::Event.new
            @current_state = Concurrent::Atom.new(initial_state)
            @state_queue = Queue.new
            @sync_latch = Concurrent::Atom.new(nil)
            @poll_thread_error = Concurrent::Atom.new(nil)
            @poll_thread_exit_sync = Mutex.new
            @last_read_state = nil
            if initial_state
                state_queue.push(initial_state)
            end

            period = self.period
            exit_condition.reset
        end

        def start
            @poll_thread = Thread.new do
                poll_loop
            end
            resume
        end

        # The internal polling loop
        def poll_loop
            # Analysis to avoid deadlocking in {#wait}
            #
            # In the ensure block:
            # - we've had an exception and poll_thread_error is set
            # - the loop quit because exit_condition was set
            #
            # We synchronize the latch (from wait) and we set exit_condition in
            # the synchronization section to ensure that {#wait} can check for
            # exit_condition being set and set the latch only if it is not
            last_state = nil
            until exit_condition.set?
                if latch = sync_latch.value
                    latch.count_down
                end

                time = Time.now
                state = orocos_task.rtt_state
                if (state != last_state) || !current_state.value
                    current_state.reset(state)
                    state_queue.push(state)
                    last_state = state
                end
                if latch
                    latch.count_down
                    sync_latch.reset(nil)
                end
                spent = (Time.now - time)
                if spent < period
                    exit_condition.wait(period - spent)
                end
                run_event.wait
            end
        rescue Exception => e
            poll_thread_error.reset(e)
        ensure
            poll_thread_exit_sync.synchronize do
                exit_condition.set
                if latch = sync_latch.value
                    latch.count_down
                    latch.count_down
                end
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

        # Wait for the current state to be read and return it
        def wait
            validate_thread_running

            latch = poll_thread_exit_sync.synchronize do
                if !run_event.set?
                    raise ThreadError, "#{self} is paused, cannot call #wait"
                elsif error = poll_thread_error.value
                    raise error, "#{self}'s poll thread quit with #{error.message}, cannot call #wait", (error.backtrace + caller)
                elsif exit_condition.set?
                    raise ThreadError, "#{self} is quitting, cannot call #wait"
                end

                sync_latch.reset(latch = Concurrent::CountDownLatch.new(2))
                latch
            end

            latch.wait
            if error = poll_thread_error.value
                raise error, "#{self}'s poll thread quit with #{error.message} during #wait", (error.backtrace + caller)
            elsif exit_condition.set?
                raise ThreadError, "#{self}#disconnect called within #wait"
            else
                current_state.value
            end
        end

        # Whether the state reader has read at least one state
        def ready?
            last_read_state || !state_queue.empty?
        end

        # Read either a new or the last read state
        def read
            read_new || last_read_state
        end

        # Read a new state change
        def read_new
            if new_state = state_queue.pop(true)
                @last_read_state = new_state
            end
        rescue ThreadError
        end

        def clear
            state_queue.clear
            current_state.reset(nil)
            @last_read_state = nil
        end

        # Whether the polling thread is alive
        def connected?
            @poll_thread && !exit_condition.set?
        end

        # Pause polling until {#resume} or {#disconnect} are called
        def pause
            validate_thread_running

            run_event.reset
        end

        # Resume polling after a {#pause}
        #
        # It is safe to call even if the polling is currently active
        def resume
            validate_thread_running

            run_event.set
        end

        # Stop polling completely
        #
        # After calling {#disconnect}, the reader cannot be connected again. Use
        # {#pause} and {#resume} to temporarily stop polling
        def disconnect
            # This order ensures that {#poll_thread} will quit immediately if it
            # was paused
            exit_condition.set
            run_event.set
        end

        # Wait for the poll thread to finish after a {#disconnect}
        def join
            poll_thread&.join
        end
    end
end
