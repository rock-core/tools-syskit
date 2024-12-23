# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"
require "syskit/test/polling_executor"

module Syskit
    module Telemetry
        module Async
            describe OutputReader do
                before do
                    @connection_executor = Test::PollingExecutor.new
                    @disconnection_executor = Test::PollingExecutor.new
                    @read_executor = Test::PollingExecutor.new
                    @ruby_tasks = []
                end

                after do
                    @ruby_tasks.each(&:dispose)
                end

                it "asynchronously connects to the port" do
                    _, async = make_async_task("test")
                    reader = make_reader(async.port("out"))

                    execute_all(@connection_executor)
                    reader.poll
                    assert reader.connected?
                end

                describe "#disconnect" do
                    before do
                        @task, @async = make_async_task("test")
                    end

                    it "asynchronously disconnects" do
                        reader = make_connected_reader(@async.port("out"))
                        flexmock(reader.raw_reader).should_receive(:disconnect).once
                        future = reader.disconnect
                        execute_all(@disconnection_executor)
                        future.value!
                    end

                    it "synchronizes the disconnection on the last read" do
                        reader = make_connected_reader(@async.port("out"))
                        executed = []
                        3.times do |i|
                            reader.raw_read_new(@read_executor).then { executed << i }
                        end
                        future = reader.disconnect.then { executed << 3 }

                        execute_all(@disconnection_executor)
                        execute_all(@read_executor)
                        execute_all(@disconnection_executor)
                        future.value!

                        assert_equal (0...4).to_a, executed
                    end

                    it "synchronizes the disconnection on the connection" do
                        reader = make_reader(@async.port("out"))
                        executed = []
                        flexmock(Orocos::OutputReader)
                            .new_instances.should_receive(:disconnect).once
                        future = reader.disconnect.then { executed << 1 }

                        execute_all(@disconnection_executor)
                        execute_all(@connection_executor)
                        execute_all(@disconnection_executor)
                        future.value!
                    end
                end

                describe "#raw_read_with_result" do
                    before do
                        @task, @async = make_async_task("test")
                    end

                    it "makes all reads sequential" do
                        reader = make_reader(@async.port("out"))
                        @task.out.write(42)
                        executor0 = Test::PollingExecutor.new
                        executor1 = Test::PollingExecutor.new
                        future0 = reader.raw_read_with_result(executor0)
                        future1 = reader.raw_read_with_result(executor1)

                        execute_all(executor1)
                        refute future1.resolved?
                        execute_all(executor0)
                        assert future0.resolved?
                        execute_all(executor1)
                        assert future1.resolved?
                    end

                    it "returns nil if the reader is disconnected, and it does not " \
                       "attempt to read the old reader object" do
                        reader = make_connected_reader(@async.port("out"))
                        flexmock(reader.raw_reader)
                            .should_receive(:raw_read_with_result)
                            .never
                        disconnect_reader(reader)

                        future = reader.raw_read_with_result(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end
                end

                describe "#raw_read" do
                    before do
                        @task, @async = make_async_task("test")
                    end

                    it "returns nil if the reader is not connected" do
                        reader = make_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end

                    it "returns nil if the reader is connected but " \
                       "there has never been any samples" do
                        reader = make_connected_reader(@async.port("out"))
                        future = reader.raw_read(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end

                    it "reads a new sample once the reader is connected" do
                        reader = make_connected_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read(@read_executor)
                        execute_all(@read_executor)
                        assert_equal 42, Typelib.to_ruby(future.value!)
                    end

                    it "returns the old sample if there are no new samples" do
                        reader = make_connected_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read(@read_executor)
                        execute_all(@read_executor)
                        assert_equal 42, Typelib.to_ruby(future.value!)

                        future = reader.raw_read(@read_executor)
                        execute_all(@read_executor)
                        assert_equal 42, Typelib.to_ruby(future.value!)
                    end
                end

                describe "#raw_read_new" do
                    before do
                        @task, @async = make_async_task("test")
                    end

                    it "returns nil if the reader is not connected" do
                        reader = make_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read_new(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end

                    it "returns nil if the reader is connected but " \
                       "there has never been any samples" do
                        reader = make_connected_reader(@async.port("out"))
                        future = reader.raw_read_new(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end

                    it "reads a new sample once the reader is connected" do
                        reader = make_connected_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read_new(@read_executor)
                        execute_all(@read_executor)
                        assert_equal 42, Typelib.to_ruby(future.value!)
                    end

                    it "returns nil if there are no new samples" do
                        reader = make_connected_reader(@async.port("out"))
                        @task.out.write(42)
                        future = reader.raw_read_new(@read_executor)
                        execute_all(@read_executor)
                        assert_equal 42, Typelib.to_ruby(future.value!)

                        future = reader.raw_read_new(@read_executor)
                        execute_all(@read_executor)
                        assert_nil future.value!
                    end
                end

                def make_ruby_task(name)
                    ruby_task = Orocos.allow_blocking_calls do
                        t = Orocos::RubyTasks::TaskContext.new(name)
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

                def make_reader(port)
                    OutputReader.new(
                        port, {},
                        connect_on: @connection_executor,
                        disconnect_on: @disconnection_executor
                    )
                end

                def make_connected_reader(port)
                    reader = make_reader(port)
                    execute_all(@connection_executor)
                    reader.poll
                    assert reader.connected?
                    reader
                end

                def disconnect_reader(reader)
                    future = reader.disconnect
                    execute_all(@disconnection_executor)
                    future.value!
                end

                def execute_all(executor)
                    Orocos.allow_blocking_calls { executor.execute_all }
                end

                def execute_one(executor)
                    Orocos.allow_blocking_calls { executor.execute_one }
                end
            end
        end
    end
end
