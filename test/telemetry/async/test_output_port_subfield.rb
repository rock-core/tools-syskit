# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"

module Syskit
    module Telemetry
        module Async
            describe OutputPortSubfield do
                before do
                    @ruby_tasks = []
                    @port_read_manager = PortReadManager.new
                end

                after do
                    @ruby_tasks.each(&:dispose)
                    @port_read_manager.dispose
                end

                it "computes the subfield name and type for compound types" do
                    _, async = make_async_task("test")
                    port = async.port("rbs").sub_port(%w[time microseconds])
                    assert_equal "/int64_t", port.type.name
                    assert_equal "rbs.time.microseconds", port.name
                end

                it "computes the subfield name and type for container types" do
                    _, async = make_async_task("test")
                    port = async.port("joints").sub_port(%w[elements 10 effort])
                    assert_equal "/float", port.type.name
                    assert_equal "joints.elements[10].effort", port.name
                end

                it "is reachable" do
                    _, async = make_async_task("test")
                    port = async.port("joints").sub_port(%w[elements 10 effort])
                    assert port.reachable?
                end

                it "becomes unreachable when the underlying port is" do
                    _, async = make_async_task("test")
                    port = async.port("joints").sub_port(%w[elements 10 effort])

                    mock = flexmock
                    mock.should_receive(:unreachable).once
                    port.on_unreachable { mock.unreachable }
                    async.port("joints").unreachable!
                    refute port.reachable?
                end

                describe "#subfield" do
                    before do
                        @task = make_ruby_task("test")
                    end

                    it "resolves a subfield in a compound type" do
                        rbs = @task.rbs.new_sample
                        rbs.raw_get(:time).microseconds = 42
                        assert_equal 42, OutputPortSubfield.resolve_subfield(
                            rbs, %w[time microseconds]
                        )
                    end

                    it "resolves a subfield in a container type" do
                        joints = @task.joints.new_sample
                        joints.elements = 11.times.map { { effort: _1 } }
                        assert_equal 10, OutputPortSubfield.resolve_subfield(
                            joints, ["elements", 10, "effort"]
                        )
                    end

                    it "returns nil if the path refers to a container element that " \
                       "does not exist" do
                        joints = @task.joints.new_sample
                        joints.elements = 10.times.map { { effort: _1 } }
                        assert_nil OutputPortSubfield.resolve_subfield(
                            joints, ["elements", 10, "effort"]
                        )
                    end
                end

                it "yields the subfield's data when available" do
                    task, async = make_async_task("test")
                    full_port = async.port("joints")
                    port = full_port.sub_port(%w[elements 10 effort])

                    received = []
                    port.on_raw_data do |value|
                        received << value
                    end

                    assert_polling_eventually do
                        @port_read_manager.find_poller_for_port(full_port).connected?
                    end

                    Orocos.allow_blocking_calls do
                        joint_states = 11.times.map { |i| { effort: i } }
                        task.joints.write({ elements: joint_states })
                    end

                    assert_polling_eventually { received == [10] }
                end

                def make_ruby_task(name)
                    ruby_task = Orocos.allow_blocking_calls do
                        t = Orocos::RubyTasks::TaskContext.new(name)
                        t.create_output_port "rbs", "/base/samples/RigidBodyState"
                        t.create_output_port "joints", "/base/samples/Joints"
                        t
                    end
                    @ruby_tasks << ruby_task
                    ruby_task
                end

                def make_async_task(name)
                    t = make_ruby_task name
                    async = Orocos.allow_blocking_calls do
                        TaskContext.discover(t, port_read_manager: @port_read_manager)
                    end
                    [t, async]
                end

                def assert_polling_eventually(period: 0.01, timeout: 2, &block)
                    deadline = Time.now + timeout
                    while Time.now < deadline
                        @port_read_manager.poll
                        return if block.call

                        sleep(period)
                    end

                    flunk("condition not reached in #{timeout} seconds")
                end
            end
        end
    end
end
