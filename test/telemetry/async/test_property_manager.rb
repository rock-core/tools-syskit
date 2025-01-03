# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async"
require "syskit/interface/v2"

module Syskit
    module Telemetry
        module Async
            PropertyUpdates = Interface::V2::Protocol::PropertyUpdates
            PropertyTaskUpdates = Interface::V2::Protocol::PropertyTaskUpdates
            PropertyUpdate = Interface::V2::Protocol::PropertyUpdate
            TypelibValue = Interface::V2::Protocol::TypelibValue

            describe PropertyManager do
                before do
                    @manager = PropertyManager.new
                    @port_read_manager = PortReadManager.new
                    @ruby_tasks = []
                end

                after do
                    @manager.dispose
                    @port_read_manager.dispose
                    @ruby_tasks.each(&:dispose)
                end

                describe "#register_callback" do
                    it "registers callbacks" do
                        _, async = make_async_task("test")
                        prop = async.property("prop")

                        callback = proc {}
                        @manager.register_callback(async.property("prop"), callback)
                        assert @manager.callback_for_property?(prop)
                        assert @manager.callback_for_task_by_name?("test")
                    end

                    it "deregisters callbacks once the returned disposable is used" do
                        _, async = make_async_task("test")
                        prop = async.property("prop")

                        callback = proc {}
                        disposable = @manager.register_callback(prop, callback)
                        disposable.dispose
                        refute @manager.callback_for_property?(prop)
                        refute @manager.callback_for_task_by_name?("test")
                    end

                    it "keeps other callbacks when deregistering one" do
                        _, async = make_async_task("test")
                        prop = async.property("prop")
                        prop2 = async.property("prop2")

                        callback = proc {}
                        disposable = @manager.register_callback(prop, callback)
                        callback2 = proc {}
                        disposable2 = @manager.register_callback(prop, callback2)
                        callback3 = proc {}
                        disposable3 = @manager.register_callback(prop2, callback3)
                        disposable.dispose
                        assert @manager.callback_for_property?(prop)
                        assert @manager.callback_for_property?(prop2)
                        assert @manager.callback_for_task_by_name?("test")
                        disposable2.dispose
                        refute @manager.callback_for_property?(prop)
                        assert @manager.callback_for_property?(prop2)
                        assert @manager.callback_for_task_by_name?("test")
                        disposable3.dispose
                        refute @manager.callback_for_property?(prop)
                        refute @manager.callback_for_property?(prop2)
                        refute @manager.callback_for_task_by_name?("test")
                    end
                end

                describe "#process_updates" do
                    it "filters out updates whose type is unknown" do
                        updates = make_property_updates(
                            task_name: "test",
                            task_id: nil,
                            property_name: "prop",
                            type_name: "/unknown_t",
                            value: nil
                        )
                        missing = @manager.process_updates(updates)
                        assert_equal updates, missing
                    end

                    it "dispatches updates whose type is known" do
                        registry = Typelib::CXXRegistry.new
                        known_t = registry.create_numeric "/known_t", 4, :sint
                        @manager.update_registry(registry)

                        updates = make_property_updates(
                            task_name: "test",
                            task_id: nil,
                            property_name: "prop",
                            type_name: "/known_t",
                            value: known_t.zero
                        )

                        _, async = make_async_task("test")

                        recorder = flexmock
                        recorder.should_receive(:called).with(known_t.zero).once
                        callback = proc { recorder.called(_1) }
                        @manager.register_callback(
                            async.property("prop"),
                            callback
                        )
                        missing = @manager.process_updates(updates)
                        assert_nil missing
                    end

                    def make_property_updates(
                        task_name:, task_id:, property_name:, type_name:, value:
                    )
                        value = TypelibValue.new(
                            bytes: value&.to_byte_array, type_name: type_name
                        )
                        property = PropertyUpdate.new(
                            time: Time.now, name: property_name, value: value
                        )
                        task_update = PropertyTaskUpdates.new(
                            name: task_name, id: task_id, properties: [property]
                        )
                        PropertyUpdates.new(
                            time: Time.now, task_updates: [task_update]
                        )
                    end
                end

                def make_ruby_task(name)
                    ruby_task = Orocos.allow_blocking_calls do
                        t = Orocos::RubyTasks::TaskContext.new(name)
                        t.create_property "prop", "/int32_t"
                        t.create_property "prop2", "/int32_t"
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
            end
        end
    end
end
