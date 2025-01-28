# frozen_string_literal: true

require "syskit/test/self"
require "syskit/telemetry/async/name_service"

module Syskit
    module Telemetry
        module Async
            describe NameService do
                before do
                    @ns = NameService.new
                    @ruby_tasks = []
                end

                after do
                    @ruby_tasks.each(&:dispose)
                end

                describe "asynchronous update" do
                    it "asynchronously resolves a task from name and IOR" do
                        deployed_task, task = make_deployed_task("test", "something")

                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks
                        assert_equal task.ior, @ns.get("test").ior
                    end

                    it "does not re-resolve a registered task if the IOR matches" do
                        deployed_task, = make_deployed_task("test", "something")
                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        @ns.async_update_tasks([deployed_task])
                        refute @ns.has_pending_discoveries?
                    end

                    it "re-resolves a registered task if the IOR differs" do
                        deployed_task, = make_deployed_task("test", "something")
                        deployed_task2, task2 = make_deployed_task("test", "something")

                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks

                        @ns.async_update_tasks([deployed_task2])
                        assert @ns.has_pending_discoveries?
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks
                        assert_equal task2.ior, @ns.get("test").ior
                    end

                    it "requeues the discovery if a task's IOR changed" do
                        deployed_task, = make_deployed_task("test", "something")
                        deployed_task2, task2 = make_deployed_task("test", "something")

                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        @ns.async_update_tasks([deployed_task2])
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks
                        assert_equal task2.ior, @ns.get("test").ior
                    end

                    it "does not register a task if it has been removed while it was " \
                       "being discovered" do
                        deployed_task, = make_deployed_task("test", "something")

                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        # async_update_tasks resolves the discovered tasks
                        @ns.async_update_tasks([])
                        refute @ns.include?("test")
                        refute @ns.has_pending_discoveries?
                    end

                    it "deregisters tasks that are not in the set of known tasks" do
                        deployed_task, = make_deployed_task("test", "something")

                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks

                        @ns.async_update_tasks([])
                        refute @ns.has_pending_discoveries?
                        refute @ns.include?("test")
                    end

                    it "stops the discovery of an IOR if its resolution failed" do
                        deployed_task, = make_deployed_task("test", "something")

                        flexmock(Orocos::TaskContext)
                            .should_receive(:new)
                            .once.and_raise(RuntimeError.new("some reason"))

                        @ns.async_update_tasks([deployed_task])
                        assert @ns.has_pending_discoveries?
                        @ns.wait_for_task_discovery
                        @ns.resolve_discovered_tasks
                        refute @ns.has_pending_discoveries?
                        refute @ns.include?("test")
                    end

                    it "raises in resolve_discovered_tasks if an unexpected exceptions " \
                       "was raised by discover_task" do
                        error_m = Class.new(RuntimeError)
                        flexmock(@ns).should_receive(:discover_task).and_raise(error_m)
                        deployed_task, = make_deployed_task("test", "something")
                        @ns.async_update_tasks([deployed_task])
                        @ns.wait_for_task_discovery
                        assert_raises(NameService::AsyncDiscoveryError) do
                            @ns.resolve_discovered_tasks
                        end
                    end
                end

                describe "on_task_added" do
                    it "calls the block when a new task is registered" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test").once
                        @ns.on_task_added { |name| mock.registered(name) }
                        @ns.register(flexmock, name: "test")
                    end

                    it "already has registered the task when the callback is called" do
                        test_task = flexmock
                        mock = flexmock
                        mock.should_receive(:registered).with(test_task).once
                        @ns.on_task_added do |name|
                            mock.registered(@ns.get(name))
                        end

                        @ns.register(test_task, name: "test")
                    end

                    it "accepts more than one callback" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test", 1).once
                        mock.should_receive(:registered).with("test", 2).once
                        @ns.on_task_added { |name| mock.registered(name, 1) }
                        @ns.on_task_added { |name| mock.registered(name, 2) }

                        @ns.register(flexmock, name: "test")
                    end

                    it "processes all callbacks even if one raises" do
                        mock = flexmock
                        mock.should_receive(:registered).with("test", 1).once
                        mock.should_receive(:registered).with("test", 2).once
                        error_m = Class.new(RuntimeError)
                        @ns.on_task_added do |name|
                            mock.registered(name, 1)
                            raise error_m
                        end
                        @ns.on_task_added { |name| mock.registered(name, 2) }

                        assert_raises(error_m) do
                            @ns.register(flexmock, name: "test")
                        end
                    end

                    it "stops calling after the callback is disposed" do
                        mock = flexmock
                        mock.should_receive(:registered).never
                        @ns.on_task_added { |name| mock.registered(name) }
                           .dispose

                        @ns.register(flexmock, name: "test")
                    end
                end

                describe "on_task_removed" do
                    before do
                        @ns.register(@test_task = flexmock, name: "test")
                    end

                    it "calls the block when a task is removed" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test").once
                        @ns.on_task_removed { |name| mock.removed(name) }
                        @ns.deregister("test")
                    end

                    it "already has removed the task when the callback is called" do
                        @ns.on_task_removed do |name|
                            refute @ns.include?(name)
                        end

                        @ns.deregister("test")
                    end

                    it "accepts more than one callback" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test", 1).once
                        mock.should_receive(:removed).with("test", 2).once
                        @ns.on_task_removed { |name| mock.removed(name, 1) }
                        @ns.on_task_removed { |name| mock.removed(name, 2) }

                        @ns.deregister("test")
                    end

                    it "processes all callbacks even if one raises" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test", 1).once
                        mock.should_receive(:removed).with("test", 2).once
                        error_m = Class.new(RuntimeError)
                        @ns.on_task_removed do |name|
                            mock.removed(name, 1)
                            raise error_m
                        end
                        @ns.on_task_removed { |name| mock.removed(name, 2) }

                        assert_raises(error_m) { @ns.deregister("test") }
                    end

                    it "stops calling after the callback is disposed" do
                        mock = flexmock
                        mock.should_receive(:removed).never
                        @ns.on_task_removed { |name| mock.removed(name) }
                           .dispose

                        @ns.deregister("test")
                    end

                    it "is called for all tasks when the name service is cleared, " \
                       "after the items have been removed" do
                        mock = flexmock
                        mock.should_receive(:removed).with("test", false).once
                        @ns.on_task_removed do |name|
                            mock.removed(name, @ns.include?("test"))
                        end

                        @ns.cleanup
                    end
                end

                describe "#get" do
                    it "raises if the task is not registered" do
                        assert_raises(Orocos::NotFound) do
                            @ns.get("does_not_exist")
                        end
                    end
                end

                describe "#ior" do
                    it "returns the IOR of a registered task" do
                        _, task = make_deployed_task("test", "some")
                        @ns.register(task)
                        assert_equal task.ior, @ns.ior("test")
                    end

                    it "does not return the IOR of a task being discovered" do
                        deployed_task, = make_deployed_task("test", "some")
                        @ns.async_update_tasks([deployed_task])
                        assert_raises(Orocos::NotFound) do
                            @ns.ior("test")
                        end
                    end

                    it "raises if the given name is not registered" do
                        assert_raises(Orocos::NotFound) do
                            @ns.ior("test")
                        end
                    end
                end

                def deployed_task_s
                    @deployed_task_s ||=
                        Struct.new(:name, :ior, :orogen_model_name, keyword_init: true)
                end

                def make_deployed_task(name, orogen_model_name)
                    task = make_ruby_task(name)
                    deployed_task = deployed_task_s.new(
                        name: name, ior: task.ior, orogen_model_name: orogen_model_name
                    )
                    [deployed_task, task]
                end

                def make_ruby_task(name)
                    t = Orocos.allow_blocking_calls do
                        Orocos::RubyTasks::TaskContext.new(name)
                    end
                    @ruby_tasks << t
                    t
                end
            end
        end
    end
end
