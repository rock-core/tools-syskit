# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe RemoteStateGetter do
        attr_reader :getter, :task, :task_m
        before do
            @task = RemoteStateGetterStubTaskContext.new
            @getter = RemoteStateGetter.new(task)
            getter.start
        end

        after do
            getter.disconnect
            getter.join
        end

        describe "not-yet-started getters" do
            before do
                @getter = RemoteStateGetter.new(@task)
            end

            it "raises on #resume" do
                assert_raises(RemoteStateGetter::NotYetStarted) do
                    @getter.resume
                end
            end

            it "does nothing on #disconnect" do
                getter.disconnect
            end

            it "does nothing on #join" do
                getter.join
            end
        end

        describe "#initialize" do
            it "accepts an initial state" do
                getter = RemoteStateGetter.new(task, initial_state: 1)
                getter.start
                assert_equal 0, getter.wait
                assert_equal 1, getter.read_new
                assert_equal 0, getter.read_new
            end
        end

        describe "#connected?" do
            it "returns true if the getter is active" do
                assert getter.connected?
            end
            it "returns false once the getter is being disconnected" do
                getter.disconnect
                refute getter.connected?
            end
        end

        describe "#read_new" do
            it "returns the initial state" do
                getter.wait
                assert_equal 0, getter.read_new
            end
            it "does not queue the state if it did not change" do
                getter.wait
                getter.wait
                getter.wait
                assert_equal 0, getter.read_new
                assert_nil getter.read_new
            end
            it "queues state changes" do
                task.push_state(1)
                task.push_state(2)
                getter.wait
                getter.wait
                getter.wait
                assert_equal 0, getter.read_new
                assert_equal 1, getter.read_new
                assert_equal 2, getter.read_new
                assert_nil getter.read_new
            end
        end

        describe "#read" do
            it "returns the initial state" do
                getter.wait
                assert_equal 0, getter.read
            end
            it "queues state changes" do
                task.push_state(1)
                task.push_state(2)
                getter.wait
                getter.wait
                getter.wait
                assert_equal 0, getter.read
                assert_equal 1, getter.read
                assert_equal 2, getter.read
                assert_equal 2, getter.read
                assert_equal 2, getter.read
            end
        end

        describe "#wait" do
            it "ensures that the poll loop has read the state at least once" do
                assert_equal 0, getter.wait
            end
            it "does not affect #read_new" do
                assert_equal 0, getter.wait
                task.push_state(1)
                assert_equal 1, getter.wait
                assert_equal 0, getter.read_new
                assert_equal 1, getter.read_new
                assert_nil getter.read_new
            end

            def assert_interrupts_wait(error_class, error_message_match)
                loop do
                    task = RemoteStateGetterStubTaskContext.new
                    getter = RemoteStateGetter.new(task)
                    getter.start
                    getter.wait
                    if rand > 0.5
                        getter_thread = Thread.new { getter.wait }
                        Thread.new { yield(task, getter) }
                    else
                        Thread.new { yield(task, getter) }
                        getter_thread = Thread.new { getter.wait }
                    end
                    getter_thread.report_on_exception = false

                    begin
                        assert_equal 0, getter_thread.value
                    rescue error_class => e
                        if error_message_match === e.message
                            return e
                        end
                    end
                end
            end

            it "raises if the getter is paused" do
                getter.pause
                e = assert_raises(ThreadError) do
                    getter.wait
                end
                assert_match /is paused, cannot call #wait/, e.message
            end

            it "gets interrupted and raises if the poll thread raises" do
                error_m = Class.new(RuntimeError)
                assert_interrupts_wait(error_m, /poll thread quit.*during #wait/) do |task, _|
                    task.raise_error = error_m
                end
            end

            it "raises if the poll thread is terminated" do
                error_m = Class.new(RuntimeError)
                task.raise_error = error_m
                getter.resume
                getter.poll_thread.join
                assert_raises(error_m) do
                    getter.wait
                end
            end

            it "raises if the poll thread quits while waiting" do
                assert_interrupts_wait(ThreadError, /disconnect called within #wait/) do |_, getter|
                    getter.disconnect
                end
            end

            it "raises if the poll thread has quit or is quitting" do
                getter.disconnect
                e = assert_raises(ThreadError) do
                    getter.wait
                end
                assert_match /is quitting, cannot call #wait/, e.message
            end
        end

        describe "#ready?" do
            it "returns false if no state was read" do
                refute getter.ready?
            end
            it "returns true if at least one state was read" do
                getter.resume
                getter.wait
                assert getter.ready?
            end
        end

        describe "pause and resume" do
            it "pauses the polling thread" do
                getter.wait
                getter.pause
                while getter.poll_thread.status != "sleep"
                    Thread.pass
                end
            end
            it "allows to resume polling" do
                getter.pause
                getter.resume
                assert(getter.poll_thread.status != "sleep")
            end
        end

        describe "#clear" do
            it "clears the last read value" do
                task.push_state(1)
                getter.wait
                getter.read
                getter.clear
                refute getter.read
            end
            it "clears the state queue" do
                task.push_state(1)
                getter.wait
                getter.clear
                refute getter.read_new
            end
            it "re-reads the state even if it did not change w.r.t. the last state read" do
                # the getter usually does not queue a state if it was the same
                # than the last read state. It however should after a #clear
                task.push_state(1)
                getter.wait
                getter.clear
                assert_equal 1, getter.wait
            end
        end
    end

    class RemoteStateGetterStubTaskContext
        def initialize
            @state_queue = Queue.new
            @state = Concurrent::Atom.new(nil)
            @error = Concurrent::Atom.new(nil)
            push_state(0)
        end

        def push_state(value)
            @state_queue.push(value)
            @state.reset(value)
        end

        def rtt_state
            if error = @error.value
                raise error
            end

            begin
                @state_queue.pop(true)
            rescue ThreadError
                @state.value
            end
        end

        def raise_error=(error)
            @error.reset(error)
        end
    end
end
