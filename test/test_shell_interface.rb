# frozen_string_literal: true

require "syskit/test/self"
require "syskit/shell_interface"

module Syskit
    describe ShellInterface do
        attr_reader :subject

        before do
            @subject = ShellInterface.new(flexmock(plan: plan))
            subject.execution_engine.thread = Thread.current
            @interface_thread = nil
        end

        after do
            @ee_thread&.join
        end

        describe "#redeploy" do
            it "triggers a full deployment" do
                flexmock(Runtime).should_receive(:apply_requirement_modifications)
                                 .with(subject.plan, force: true).once.pass_thru
                subject.redeploy
            end
        end

        describe "#restart_deployments" do
            attr_reader :task_m, :task
            before do
                @task_m = TaskContext.new_submodel
                @task = syskit_stub_deploy_configure_and_start(
                    syskit_stub_requirements(task_m).with_conf("default")
                )
                plan.add_mission_task(task)
            end

            it "stops the matching deployments and redeploys" do
                plug_apply_requirement_modifications
                expect_execution do
                    subject.restart_deployments
                end.to do
                    emit find_tasks(ShellInterface::ShellDeploymentRestart).stop_event
                end
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end

            it "restricts the deployments to the given models" do
                other = syskit_stub_deploy_configure_and_start(
                    syskit_stub_requirements(TaskContext.new_submodel)
                )
                plug_apply_requirement_modifications
                expect_execution do
                    subject.restart_deployments(task.execution_agent.model)
                end.to do
                    emit find_tasks(ShellInterface::ShellDeploymentRestart).stop_event
                    emit task.stop_event
                    not_emit other.stop_event
                end
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end

            it "accepts task models as argument" do
                other = syskit_stub_deploy_configure_and_start(
                    syskit_stub_requirements(TaskContext.new_submodel)
                )
                plug_apply_requirement_modifications
                expect_execution do
                    subject.restart_deployments(task.model)
                end.to do
                    emit find_tasks(ShellInterface::ShellDeploymentRestart).stop_event
                    emit task.stop_event
                    not_emit other.stop_event
                end
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end
        end

        describe "#stop_deployments" do
            attr_reader :task_m, :task
            before do
                @task_m = TaskContext.new_submodel
                @task = syskit_stub_deploy_configure_and_start(task_m.with_conf("default"))
                plan.add_mission_task(task)
            end

            it "stops the matching deployments" do
                expect_execution { subject.stop_deployments }
                    .to do
                        emit task.aborted_event
                        emit task.execution_agent.stop_event
                    end
                assert task.finished?
            end

            it "restricts the deployments to the given models" do
                other = syskit_stub_deploy_configure_and_start(task_m.with_conf("other"))
                subject.plan.add_mission_task(other)
                expect_execution { subject.stop_deployments(task.execution_agent.model) }
                    .to do
                        emit task.aborted_event
                        emit task.execution_agent.stop_event
                    end
                assert task.finished?
                assert !other.finished?
            end

            it "accepts task models as argument" do
                other_m = TaskContext.new_submodel
                other = syskit_stub_deploy_configure_and_start(other_m)
                subject.plan.add_mission_task(other)
                expect_execution { subject.stop_deployments(task.execution_agent.model) }
                    .to do
                        emit task.aborted_event
                        emit task.execution_agent.stop_event
                    end
                assert task.finished?
                assert !other.finished?
            end
        end

        describe "the log configuration management" do
            before { Syskit.conf.logs.create_group "test" }
            after { Syskit.conf.logs.remove_group("test") }

            it "creates a marshallable instance of the configuration" do
                conf = subject.logging_conf
                assert_equal conf.port_logs_enabled, Syskit.conf.logs.port_logs_enabled?
                assert_equal conf.conf_logs_enabled, Syskit.conf.logs.conf_logs_enabled?
                Syskit.conf.logs.groups.each_pair do |key, group|
                    assert_equal group.enabled?, conf.groups[key].enabled
                end
                Marshal.dump(conf)
            end

            it "changes status of conf and port logging and redeploys" do
                conf = subject.logging_conf
                previous_port_status = Syskit.conf.logs.port_logs_enabled?
                previous_conf_status = Syskit.conf.logs.conf_logs_enabled?

                conf.port_logs_enabled = !previous_port_status
                conf.conf_logs_enabled = !previous_conf_status

                flexmock(subject).should_receive(:redeploy).once.pass_thru do
                    assert_equal Syskit.conf.logs.port_logs_enabled?, !previous_port_status
                    assert_equal Syskit.conf.logs.conf_logs_enabled?, !previous_conf_status
                end
                subject.update_logging_conf(conf)
            end

            it "changes status of an existing log group and redeploys" do
                conf = subject.logging_conf
                previous_status = Syskit.conf.logs.group_by_name("test").enabled?
                conf.groups["test"].enabled = !previous_status

                flexmock(subject).should_receive(:redeploy).once.pass_thru do
                    assert_equal Syskit.conf.logs.group_by_name("test").enabled?, !previous_status
                end
                subject.update_logging_conf(conf)
            end
        end

        describe "the log group management" do
            attr_reader :group
            before do
                @group = Syskit.conf.logs.create_group "test" do |g|
                    g.add /base.samples.frame.Frame/
                end
            end

            after do
                Syskit.conf.logs.remove_group("test")
            end

            it "enable_log_group enables the log group and redeploys" do
                group.enabled = false
                flexmock(subject).should_receive(:redeploy).once.ordered
                subject.enable_log_group "test"
                assert group.enabled?
            end

            it "disable_log_group enables the log group and redeploys" do
                group.enabled = true
                flexmock(subject).should_receive(:redeploy).once.ordered
                subject.disable_log_group "test"
                assert !group.enabled?
            end

            it "enable_log_group raises ArgumentError if the log group does not exist" do
                assert_raises(ArgumentError) do
                    subject.enable_log_group "does_not_exist"
                end
            end

            it "disable_log_group raises ArgumentError if the log group does not exist" do
                assert_raises(ArgumentError) do
                    subject.disable_log_group "does_not_exist"
                end
            end
        end

        # Start a thread to do a call on the interface that is synchronized
        # with {ExecutionEngine#execute}
        #
        # @example call the 'redeploy' interface command, and wait for its
        #   result
        #
        #   # Call 'redeploy'. The queue method waits 50ms to give time to
        #   # the thread to actually start the call. There's no way to be
        #   # sure, so that might lead to random test failures
        #   queue_execute_call { subject.redeploy }
        #   # Force processing of the call, and wait for the thread to
        #   # finish
        #   process_execute_call
        def queue_execute_call(&block)
            if @interface_thread
                raise "you must call #process_execute_call after a call "\
                      "to #queue_execute_call"
            end

            @interface_thread_sync = sync = Concurrent::CyclicBarrier.new(2)
            @interface_thread = Thread.new do
                sync.wait
                block.call
                sync.wait
            end
            sync.wait
            sleep 0.05
        end

        # Process the work queued with {#queue_execute_call}
        def process_execute_call
            subject.execution_engine.join_all_waiting_work
            if !@interface_thread.alive?
                # Join the thread to have it to raise an exception that
                # would have terminated it
                @interface_thread.join
                # If no exception was risen, fail with a less helpful
                # message
                flunck("interface thread quit unexpectedly")
            else
                @interface_thread_sync.wait
                @interface_thread.join
            end
        ensure
            @interface_thread = nil
        end
    end
end
