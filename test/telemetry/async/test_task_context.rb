# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"

module Syskit
    module Telemetry
        module Async
            describe TaskContext do
                before do
                    @ns = NameService.new
                    @ruby_tasks = []
                end

                after do
                    @ruby_tasks.each(&:dispose)
                end

                describe ".discover" do
                    it "creates an async task already initialized with the remote " \
                       "task's interface" do
                        t, async = make_async_task "test"
                        assert async.reachable?
                        assert_equal t.ior, async.identity
                        assert_equal Set["state", "in", "out"], async.each_port.to_set(&:name)
                        assert_equal ["prop"], async.each_property.map(&:name)
                        assert_includes async.each_attribute.map(&:name), "attr"
                    end
                end

                describe "state change notifications" do
                    it "adds a callback that is called when a state change " \
                       "is received by #poll" do
                        task, async = make_async_task "test"

                        states = []
                        async.on_state_change { states << _1 }
                        assert_polling_eventually(async) { states == [:PRE_OPERATIONAL] }

                        Orocos.allow_blocking_calls do
                            task.configure
                            task.start
                        end
                        assert_polling_eventually(async) do
                            states == %I[PRE_OPERATIONAL STOPPED RUNNING]
                        end
                    end
                    it "calls the block with the currently known state" do
                        task, async = make_async_task "test"
                        Orocos.allow_blocking_calls do
                            task.configure
                            task.start
                        end
                        states = []
                        async.on_state_change { states << _1 }
                        assert_polling_eventually(async) do
                            states[-1] == :RUNNING
                        end

                        states = []
                        async.on_state_change { states << _1 }
                        assert_equal [:RUNNING], states
                    end

                    it "does not call the block is no state is known" do
                        _, async = make_async_task "test"
                        record = flexmock
                        record.should_receive(:called).never
                        async.on_state_change { record.called }
                    end
                end

                describe "reachability" do
                    it "is reachable right after .discover" do
                        _, async = make_async_task "test"
                        assert async.reachable?
                    end

                    it "calls the reachability callback on registration" do
                        _, async = make_async_task "test"
                        record = flexmock
                        record.should_receive(:called).once
                        async.on_reachable { record.called }
                    end

                    it "calls on_unreachable when unreachable! is called" do
                        _, async = make_async_task "test"
                        record = flexmock
                        record.should_receive(:called).once
                        async.on_unreachable { record.called }
                        async.unreachable!
                    end

                    it "does not call new reachable callbacks " \
                       "if the task is not reachable" do
                        _, async = make_async_task "test"
                        async.unreachable!
                        record = flexmock
                        record.should_receive(:called).never
                        async.on_reachable { record.called }
                    end
                end

                describe "attributes" do
                    it "calls the on_attribute_reachable hooks on registration" do
                        _, async = make_async_task "test"
                        attributes = []
                        async.on_attribute_reachable { attributes << _1 }
                        assert_includes attributes, "attr"
                    end

                    it "calls the attribute's on_reachable hook on registration" do
                        _, async = make_async_task "test"
                        m = flexmock
                        m.should_receive(:called).once
                        async.attribute("attr").on_reachable { m.called }
                    end

                    it "calls the on_attribute_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        attributes = []
                        async.on_attribute_unreachable { attributes << _1 }
                        async.unreachable!
                        assert_includes attributes, "attr"
                    end

                    it "calls the attribute's on_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        m = flexmock
                        m.should_receive(:called).once
                        async.attribute("attr").on_unreachable { m.called }
                        async.unreachable!
                    end
                end

                describe "properties" do
                    it "calls the on_property_reachable hooks on registration" do
                        _, async = make_async_task "test"
                        properties = []
                        async.on_property_reachable { properties << _1 }
                        assert_equal ["prop"], properties
                    end

                    it "calls the property's on_reachable hook on registration" do
                        _, async = make_async_task "test"
                        m = flexmock
                        m.should_receive(:called).once
                        async.property("prop").on_reachable { m.called }
                    end

                    it "calls the on_property_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        properties = []
                        async.on_property_unreachable { properties << _1 }
                        async.unreachable!
                        assert_equal ["prop"], properties
                    end

                    it "calls the propertie's on_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        properties = []
                        async.on_property_reachable { properties << _1 }
                        m = flexmock
                        m.should_receive(:called).once
                        async.property("prop").on_unreachable { m.called }
                        async.unreachable!
                    end
                end

                describe "ports" do
                    it "calls the on_port_reachable hooks on registration" do
                        _, async = make_async_task "test"
                        ports = []
                        async.on_port_reachable { ports << _1 }
                        assert_equal Set["state", "in", "out"], ports.to_set
                    end

                    it "calls the attribute's on_reachable hook on registration" do
                        _, async = make_async_task "test"
                        m = flexmock
                        m.should_receive(:called).once
                        async.port("in").on_reachable { m.called }
                    end

                    it "calls the on_port_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        ports = []
                        async.on_port_unreachable { ports << _1 }
                        async.unreachable!
                        assert_equal Set["in", "out", "state"], ports.to_set
                    end

                    it "calls the port's on_unreachable hooks when " \
                       "the task becomes unreachable" do
                        _, async = make_async_task "test"
                        m = flexmock
                        m.should_receive(:called).once
                        async.port("in").on_unreachable { m.called }
                        async.unreachable!
                    end
                end

                describe "ports" do
                    it "calls the on_port_reachable hooks on registration" do
                        _, async = make_async_task "test"
                        ports = []
                        async.on_port_reachable { ports << _1 }
                        assert_equal Set["state", "in", "out"], ports.to_set(&:name)
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

                def assert_polling_eventually(async, period: 0.01, timeout: 2, &block)
                    deadline = Time.now + timeout
                    while Time.now < deadline
                        async.poll
                        return if block.call

                        sleep(period)
                    end

                    flunk("condition not reached in #{timeout} seconds")
                end
            end
        end
    end
end
