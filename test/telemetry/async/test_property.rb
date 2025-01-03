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

            describe Property do
                before do
                    @manager = PropertyManager.new
                    @port_read_manager = PortReadManager.new
                    @ruby_tasks = []

                    registry = Typelib::CXXRegistry.new
                    @known_t = registry.create_numeric "/known_t", 4, :sint
                    @manager.update_registry(registry)
                end

                after do
                    @manager.dispose
                    @port_read_manager.dispose
                    @ruby_tasks.each(&:dispose)
                end

                describe "#on_raw_change" do
                    it "registers a callback so that it receives updates" do
                        updates = make_property_updates(
                            task_name: "test",
                            task_id: nil,
                            property_name: "prop",
                            type_name: "/known_t",
                            value: @known_t.zero
                        )

                        _, async = make_async_task("test")

                        recorder = flexmock
                        recorder.should_receive(:called).with(@known_t.zero).once
                        async.property("prop").on_raw_change do
                            recorder.called(_1)
                        end

                        @manager.process_updates(updates)
                    end

                    it "stops sending updates if the returned listener is stopped" do
                        updates = make_property_updates(
                            task_name: "test",
                            task_id: nil,
                            property_name: "prop",
                            type_name: "/known_t",
                            value: @known_t.zero
                        )

                        _, async = make_async_task("test")

                        recorder = flexmock
                        recorder.should_receive(:called).never
                        listener = async.property("prop").on_raw_change do
                            recorder.called
                        end
                        listener.stop

                        @manager.process_updates(updates)
                    end
                end

                describe "#on_change" do
                    it "converts the values to Ruby types" do
                        updates = make_property_updates(
                            task_name: "test",
                            task_id: nil,
                            property_name: "prop",
                            type_name: "/known_t",
                            value: @known_t.zero
                        )

                        _, async = make_async_task("test")

                        recorder = flexmock
                        recorder.should_receive(:called).with(0).once
                        async.property("prop").on_change do
                            recorder.called(_1)
                        end

                        @manager.process_updates(updates)
                    end
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
                        TaskContext.discover(
                            t,
                            port_read_manager: @port_read_manager,
                            property_manager: @manager
                        )
                    end
                    [t, async]
                end
            end
        end
    end
end

