# frozen_string_literal: true

require "syskit/test/self"
require "syskit/interface"

module Syskit
    module Interface
        describe Commands do
            attr_reader :subject

            before do
                @subject = Commands.new(flexmock(plan: plan))
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

            describe "#deployments" do
                attr_reader :task_m, :task

                before do
                    @task_m = TaskContext.new_submodel
                    @task = syskit_stub_deploy_configure_and_start(
                        syskit_stub_requirements(task_m).with_conf("default")
                    )
                    plan.add_mission_task(task)
                end

                it "returns the list of deployments" do
                    deployments = subject.deployments
                    assert_equal 1, deployments.size
                    deployment = deployments.first
                    assert_kind_of Deployment, deployment
                    assert_equal ::Process.pid, deployment.pid
                    assert_equal "stubs", deployment.arguments[:on]
                end
            end

            describe "#poll_ready_deployments" do
                attr_reader :task_m, :task

                before do
                    @task_m = TaskContext.new_submodel
                    @task = syskit_stub_deploy_configure_and_start(
                        syskit_stub_requirements(task_m).with_conf("default")
                    )
                    plan.add_mission_task(task)
                end

                it "returns a deployment that is ready" do
                    new_deployments, old_deployments = subject.poll_ready_deployments
                    assert_equal [], old_deployments
                    assert_equal 1, new_deployments.size
                    deployment = new_deployments.first
                    assert_equal @task.execution_agent, deployment
                end

                it "ignores a deployment that is not ready yet" do
                    flexmock(@task.execution_agent).should_receive(ready?: false)
                    new_deployments, old_deployments = subject.poll_ready_deployments
                    assert_equal [], new_deployments
                    assert_equal [], old_deployments
                end

                it "does not return a deployment that is already known" do
                    new_deployments, old_deployments =
                        subject.poll_ready_deployments(
                            known: [@task.execution_agent.droby_id.id]
                        )

                    assert_equal [], new_deployments
                    assert_equal [], old_deployments
                end

                it "lists deployments that have been removed" do
                    droby_id = @task.execution_agent.droby_id.id
                    expect_execution do
                        plan.unmark_mission_task(task)
                        plan.unmark_permanent_task(task.execution_agent)
                    end.garbage_collect(true).to { emit task.execution_agent.stop_event }

                    new_deployments, old_deployments =
                        subject.poll_ready_deployments(known: [droby_id])
                    assert_equal [], new_deployments
                    assert_equal [droby_id], old_deployments
                end
            end

            describe "#poll_property_updates" do
                attr_reader :task_m, :task

                before do
                    @task_m = TaskContext.new_submodel do
                        property "p", "/double", 20
                    end

                    @task = syskit_stub_and_deploy(
                        syskit_stub_requirements(task_m).with_conf("default")
                    )
                    plan.add_mission_task(task)
                end

                it "returns nothing if no task IDs are given" do
                    now = Timecop.freeze
                    updates = subject.poll_property_updates
                    assert_equal now, updates.time
                    assert updates.per_task_id.empty?
                end

                it "ignores tasks that are not yet configured" do
                    now = Timecop.freeze
                    task_id = @task.droby_id.id
                    updates = subject.poll_property_updates(task_ids: [task_id])
                    assert_equal now, updates.time
                    assert_equal({ task_id => [] }, updates.per_task_id)
                end

                it "returns known property values" do
                    task_id = @task.droby_id.id
                    now = Timecop.freeze
                    @task.property_overrides.p = 20
                    syskit_configure(@task)

                    updates = subject.poll_property_updates(task_ids: [task_id])
                    assert_equal [task_id], updates.per_task_id.keys
                    update = updates.per_task_id[task_id].first
                    assert_equal now, update.time
                    assert_equal "p", update.property_name
                    assert_kind_of Typelib::Type, update.value
                    assert_equal 20, Typelib.to_ruby(update.value)
                end

                it "filters out updates that are strictly after now" do
                    task_id = @task.droby_id.id
                    syskit_configure(@task)

                    now = Timecop.freeze
                    updates = subject.poll_property_updates(
                        task_ids: [task_id], since: now
                    )
                    assert_equal({ task_id => [] }, updates.per_task_id)
                end

                it "includes updates whose timestamp is `since`" do
                    task_id = @task.droby_id.id
                    now = Timecop.freeze
                    syskit_configure(@task)

                    updates = subject.poll_property_updates(
                        task_ids: [task_id], since: now
                    )
                    assert_equal [task_id], updates.per_task_id.keys
                    assert_equal 1, update = updates.per_task_id[task_id].size
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
                        emit find_tasks(Commands::ShellDeploymentRestart).stop_event
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
                        emit find_tasks(Commands::ShellDeploymentRestart).stop_event
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
                        emit find_tasks(Commands::ShellDeploymentRestart).stop_event
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
                    @task = syskit_stub_deploy_configure_and_start(
                        task_m.with_conf("default")
                    )
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
                    other =
                        syskit_stub_deploy_configure_and_start(task_m.with_conf("other"))
                    subject.plan.add_mission_task(other)
                    expect_execution do
                        subject.stop_deployments(task.execution_agent.model)
                    end.to do
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
                    expect_execution do
                        subject.stop_deployments(task.execution_agent.model)
                    end.to do
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
                    assert_equal conf.port_logs_enabled,
                                 Syskit.conf.logs.port_logs_enabled?
                    assert_equal conf.conf_logs_enabled,
                                 Syskit.conf.logs.conf_logs_enabled?
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
                        assert_equal Syskit.conf.logs.port_logs_enabled?,
                                     !previous_port_status
                        assert_equal Syskit.conf.logs.conf_logs_enabled?,
                                     !previous_conf_status
                    end
                    subject.update_logging_conf(conf)
                end

                it "changes status of an existing log group and redeploys" do
                    conf = subject.logging_conf
                    previous_status = Syskit.conf.logs.group_by_name("test").enabled?
                    conf.groups["test"].enabled = !previous_status

                    flexmock(subject).should_receive(:redeploy).once.pass_thru do
                        assert_equal Syskit.conf.logs.group_by_name("test").enabled?,
                                     !previous_status
                    end
                    subject.update_logging_conf(conf)
                end
            end

            describe "the log group management" do
                attr_reader :group

                before do
                    @group = Syskit.conf.logs.create_group "test" do |g|
                        g.add(/base.samples.frame.Frame/)
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

                it "enable_log_group raises ArgumentError " \
                   "if the log group does not exist" do
                    assert_raises(ArgumentError) do
                        subject.enable_log_group "does_not_exist"
                    end
                end

                it "disable_log_group raises ArgumentError " \
                   "if the log group does not exist" do
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
                    raise "you must call #process_execute_call after a call " \
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
                if @interface_thread.alive?
                    @interface_thread_sync.wait
                    @interface_thread.join
                else
                    # Join the thread to have it to raise an exception that
                    # would have terminated it
                    @interface_thread.join
                    # If no exception was risen, fail with a less helpful
                    # message
                    flunck("interface thread quit unexpectedly")
                end
            ensure
                @interface_thread = nil
            end
        end
    end
end
