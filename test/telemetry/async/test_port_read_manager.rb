# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"
require "syskit/test/polling_executor"

module Syskit
    module Telemetry
        module Async
            describe PortReadManager do
                before do
                    @connection_executor = Test::PollingExecutor.new
                    @disconnection_executor = Test::PollingExecutor.new
                    @read_executor = Test::PollingExecutor.new
                    @manager = PortReadManager.new(
                        connection_executor: @connection_executor,
                        disconnection_executor: @disconnection_executor,
                        read_executor: @read_executor
                    )
                    @ruby_tasks = []
                end

                after do
                    @manager.dispose
                    @ruby_tasks.each(&:dispose)
                end

                describe "#register_callback" do
                    it "creates a poller when a callback is first registered" do
                        _, async = make_async_task("test")
                        @manager.register_callback(
                            async.port("out"), proc {}, period: 0.1, buffer_size: 1
                        )
                        assert @manager.polling?(async.port("out"))
                    end

                    it "keeps the current reader if the buffer size is compatible" do
                        _, async = make_async_task("test")
                        out_p = async.port("out")
                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 1
                        )
                        reader = @manager.find_poller_for_port(out_p).reader

                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 1
                        )
                        assert_same reader, @manager.find_poller_for_port(out_p).reader
                    end

                    it "creates a new reader if the buffer size is greater " \
                       "than the actual" do
                        _, async = make_async_task("test")
                        out_p = async.port("out")
                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 1
                        )
                        orig_reader = @manager.find_poller_for_port(out_p).reader

                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 5
                        )
                        reader = @manager.find_poller_for_port(out_p).reader
                        refute_same orig_reader, reader
                        assert_equal 5, reader.buffer_size
                        assert orig_reader.disposed?
                    end

                    it "updates the poller period at each new callback " \
                       "(reusing poller)" do
                        _, async = make_async_task("test")
                        out_p = async.port("out")
                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 1
                        )
                        assert_equal 0.1, @manager.find_poller_for_port(out_p).period

                        @manager.register_callback(
                            out_p, proc {}, period: 0.05, buffer_size: 1
                        )
                        assert_equal 0.05, @manager.find_poller_for_port(out_p).period
                    end

                    it "updates the poller period at each new callback " \
                       "(new poller)" do
                        _, async = make_async_task("test")
                        out_p = async.port("out")
                        @manager.register_callback(
                            out_p, proc {}, period: 0.1, buffer_size: 1
                        )
                        assert_equal 0.1, @manager.find_poller_for_port(out_p).period

                        @manager.register_callback(
                            out_p, proc {}, period: 0.05, buffer_size: 5
                        )
                        assert_equal 0.05, @manager.find_poller_for_port(out_p).period
                    end
                end

                describe "#poll" do
                    before do
                        @task, @async = make_async_task("test")
                        @received_samples = []
                        @out_p = @async.port("out")
                        @manager.register_callback(
                            @out_p,
                            proc { @received_samples << _1 },
                            period: 0.1, buffer_size: 1
                        )
                        @poller = @manager.find_poller_for_port(@out_p)
                    end

                    it "does nothing if the reader is not connected" do
                        @manager.poll
                    end

                    it "immediately schedules the next read once connected" do
                        execute_all(@connection_executor)
                        @manager.poll

                        assert @poller.reader.connected?
                        assert @poller.read_future

                        Orocos.allow_blocking_calls { @task.out.write 42 }
                        execute_all(@read_executor)
                        assert_equal 42, @poller.read_future.value
                        @manager.poll

                        assert_equal [42], @received_samples
                    end

                    it "reschedules the next read based on the read period" do
                        execute_all(@connection_executor)
                        @manager.poll

                        execute_all(@read_executor)
                        @poller.read_future.wait
                        current_t = @poller.next_time
                        time = freeze_monotonic_time

                        @manager.poll
                        next_t = @poller.next_time
                        delta_in_periods = (next_t - current_t) / 0.1
                        assert_in_delta delta_in_periods, delta_in_periods.round, 1e-6
                        assert_operator next_t, :>, time
                        assert_operator next_t - time, :<, 0.1
                    end

                    it "does not do anything for pollers whose next time " \
                       "has not been reached" do
                        execute_all(@connection_executor)
                        @manager.poll

                        execute_all(@read_executor)
                        @poller.read_future.wait
                        time = freeze_monotonic_time
                        @manager.poll
                        @manager.poll
                        refute @poller.read_future

                        freeze_monotonic_time(time + 0.1)
                        @manager.poll
                        assert @poller.read_future
                    end

                    def freeze_monotonic_time(time = @manager.monotonic_time)
                        @frozen_time = time
                        flexmock(@manager)
                            .should_receive(:monotonic_time)
                            .and_return { @frozen_time }
                        time
                    end
                end

                def make_ruby_task(name)
                    ruby_task = Orocos.allow_blocking_calls do
                        t = Orocos::RubyTasks::TaskContext.new(name)
                        t.create_attribute "attr", "/int16_t"
                        t.create_property "prop", "/int32_t"
                        t.create_input_port "in", "/float"
                        t.create_output_port "out", "/double"
                        t
                    end
                    @ruby_tasks << ruby_task
                    ruby_task
                end

                def make_async_task(name)
                    t = make_ruby_task name
                    async = Orocos.allow_blocking_calls do
                        TaskContext.discover(t)
                    end
                    [t, async]
                end

                def execute_all(executor)
                    Orocos.allow_blocking_calls { executor.execute_all }
                end
            end
        end
    end
end
