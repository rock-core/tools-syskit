# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/ui/name_service"

module Syskit
    module Telemetry
        module UI
            describe NameService do
                before do
                    @name_service = NameService.new
                end

                describe "on_task_added" do
                    it "calls the block when a new task is registered" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test").once
                        @name_service.on_task_added { |name| mock.registered(name) }
                        @name_service.register(flexmock, name: "test")
                    end

                    it "already has registered the task when the callback is called" do
                        test_task = flexmock
                        mock = flexmock
                        mock.should_receive(:registered).with(test_task).once
                        @name_service.on_task_added do |name|
                            mock.registered(@name_service.get(name))
                        end

                        @name_service.register(test_task, name: "test")
                    end

                    it "accepts more than one callback" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test", 1).once
                        mock.should_receive(:registered).with("test", 2).once
                        @name_service.on_task_added { |name| mock.registered(name, 1) }
                        @name_service.on_task_added { |name| mock.registered(name, 2) }

                        @name_service.register(flexmock, name: "test")
                    end

                    it "processes all callbacks even if one raises" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test", 1).once
                        mock.should_receive(:registered).with("test", 2).once
                        error_m = Class.new(RuntimeError)
                        @name_service.on_task_added do |name|
                            mock.registered(name, 1)
                            raise error_m
                        end
                        @name_service.on_task_added { |name| mock.registered(name, 2) }

                        assert_raises(error_m) do
                            @name_service.register(flexmock, name: "test")
                        end
                    end

                    it "stops calling after the callback is disposed" do
                        mock = flexmock
                        mock.should_receive(:registered).never
                        @name_service.on_task_added { |name| mock.registered(name) }
                                     .dispose

                        @name_service.register(flexmock, name: "test")
                    end
                end

                describe "on_task_removed" do
                    before do
                        @name_service.register(@test_task = flexmock, name: "test")
                    end

                    it "calls the block when a task is removed" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test").once
                        @name_service.on_task_removed { |name| mock.removed(name) }
                        @name_service.deregister("test")
                    end

                    it "already has removed the task when the callback is called" do
                        @name_service.on_task_removed do |name|
                            refute @name_service.include?(name)
                        end

                        @name_service.deregister("test")
                    end

                    it "accepts more than one callback" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test", 1).once
                        mock.should_receive(:removed).with("test", 2).once
                        @name_service.on_task_removed { |name| mock.removed(name, 1) }
                        @name_service.on_task_removed { |name| mock.removed(name, 2) }

                        @name_service.deregister("test")
                    end

                    it "processes all callbacks even if one raises" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test", 1).once
                        mock.should_receive(:removed).with("test", 2).once
                        error_m = Class.new(RuntimeError)
                        @name_service.on_task_removed do |name|
                            mock.removed(name, 1)
                            raise error_m
                        end
                        @name_service.on_task_removed { |name| mock.removed(name, 2) }

                        assert_raises(error_m) { @name_service.deregister("test") }
                    end

                    it "stops calling after the callback is disposed" do
                        mock = flexmock
                        mock.should_receive(:removed).never
                        @name_service.on_task_removed { |name| mock.removed(name) }
                                     .dispose

                        @name_service.deregister("test")
                    end
                end
            end
        end
    end
end
