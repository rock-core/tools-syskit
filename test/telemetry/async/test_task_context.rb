# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"

module Syskit
    module Telemetry
        module Async
            describe TaskContext do
                before do
                    @ns = NameService.new
                    @port_read_manager = PortReadManager.new
                    @ruby_tasks = []
                end

                after do
                    @port_read_manager.dispose
                    @ruby_tasks.each(&:dispose)
                end

                it "is the same as another async task with the same remote task when " \
                   "used as hash key" do
                    t, async = make_async_task "test"
                    async2 = discover_task(t)

                    _, async3 = make_async_task "test2"

                    hash = { async => 42 }
                    assert_equal 42, hash[async2]
                    assert_nil hash[async3]
                    assert_nil hash[42]
                    assert_nil hash["test"]
                end

                describe ".discover" do
                    it "creates an async task already initialized with the remote " \
                       "task's interface" do
                        t, async = make_async_task "test"
                        assert async.reachable?
                        assert_equal t.ior, async.identity
                        assert_equal Set["state", "in", "out"],
                                     async.each_port.to_set(&:name)
                        assert_equal ["prop"], async.each_property.map(&:name)
                        assert_includes async.each_attribute.map(&:name), "attr"
                    end

                    it "registers attributes" do
                        _, async = make_async_task "test"
                        attr = async.attribute("attr")
                        assert_includes async.each_attribute.to_a, attr
                        assert_kind_of Attribute, attr
                        assert_equal "attr", attr.name
                    end

                    it "registers properties" do
                        _, async = make_async_task "test"
                        prop = async.property("prop")
                        assert_equal [prop], async.each_property.to_a
                        assert_kind_of Property, prop
                        assert_equal "prop", prop.name
                    end

                    it "registers input ports" do
                        _, async = make_async_task "test"
                        in_p = async.port("in")
                        assert_equal [in_p], async.each_input_port.to_a
                        assert_includes async.each_port.to_a, in_p
                        assert_kind_of InputPort, in_p
                        assert_equal "in", in_p.name
                    end

                    it "registers output ports" do
                        _, async = make_async_task "test"
                        out_p = async.port("out")
                        assert_equal Set[async.port("state"), out_p],
                                     async.each_output_port.to_set
                        assert_includes async.each_port.to_a, out_p
                        assert_kind_of OutputPort, out_p
                        assert_equal "out", out_p.name
                    end
                end

                describe "state change notifications" do
                    it "adds a callback that is called when a state change " \
                       "is received by #poll" do
                        task, async = make_async_task "test"

                        states = []
                        async.on_state_change { states << _1 }
                        assert_polling_eventually { states == [:PRE_OPERATIONAL] }

                        Orocos.allow_blocking_calls do
                            task.configure
                            task.start
                        end
                        assert_polling_eventually do
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
                        assert_polling_eventually do
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

                    it "is usable as a hash key" do
                        t, async = make_async_task "test"
                        attr = async.attribute("attr")

                        async2 = discover_task(t)
                        attr2 = async2.attribute("attr")

                        _, async3 = make_async_task "test2"
                        attr3 = async3.attribute("attr")

                        hash = { attr => 42 }
                        assert_equal 42, hash[attr2]
                        assert_nil hash[attr3]
                        assert_nil hash[42]
                        assert_nil hash["test"]
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

                    it "is usable as a hash key" do
                        t, async = make_async_task "test"
                        prop = async.property("prop")

                        async2 = discover_task(t)
                        prop2 = async2.property("prop")

                        _, async3 = make_async_task "test2"
                        prop3 = async3.property("prop")

                        hash = { prop => 42 }
                        assert_equal 42, hash[prop2]
                        assert_nil hash[prop3]
                        assert_nil hash[42]
                        assert_nil hash["test"]
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

                    it "is usable as a hash key" do
                        t, async = make_async_task "test"
                        port = async.port("out")

                        async2 = discover_task(t)
                        port2 = async2.port("out")

                        _, async3 = make_async_task "test2"
                        port3 = async3.port("out")

                        hash = { port => 42 }
                        assert_equal 42, hash[port2]
                        assert_nil hash[port3]
                        assert_nil hash[42]
                        assert_nil hash["test"]
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
                    [t, discover_task(t)]
                end

                def discover_task(task)
                    Orocos.allow_blocking_calls do
                        TaskContext.discover(task, port_read_manager: @port_read_manager)
                    end
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
