require 'syskit/test/self'
require 'syskit/shell_interface'

module Syskit
    describe ShellInterface do
        attr_reader :subject

        before do
            @subject = ShellInterface.new(flexmock(plan: plan))
            subject.execution_engine.thread = Thread.current
            @interface_thread = nil
        end

        after do
            TaskContext.needs_reconfiguration.clear
            if @ee_thread
                @ee_thread.join
            end
        end

        describe "#redeploy" do
            it "triggers a full deployment" do
                flexmock(Runtime).should_receive(:apply_requirement_modifications).
                    with(subject.plan, force: true).once.pass_thru
                subject.redeploy
            end
        end

        describe "#reload_config" do
            it "reloads the configuration of all task context models" do
                model = TaskContext.new_submodel
                flexmock(model.configuration_manager).should_receive(:reload).once
                subject.reload_config
            end
            it "does not attempt to reload the configuration of specialized models" do
                model = TaskContext.new_submodel
                specialized = model.specialize
                # The two share the same specialization manager. If
                # #reload_config passes through the specialized models, #reload
                # would be called twice
                flexmock(specialized.configuration_manager).should_receive(:reload).once
                subject.reload_config
            end
            it "marks the tasks with changed sections as non-reusable" do
                model = TaskContext.new_submodel
                task = syskit_stub_deploy_and_configure(model)
                # NOTE: we need to mock the configuration manager AFTER the
                # model stub, as stubbing protects the original manager
                flexmock(model.configuration_manager).should_receive(:reload).once.
                    and_return(['default'])
                flexmock(::Robot).should_receive(:info).with("task #{task.orocos_name} needs reconfiguration").once
                subject.reload_config
                assert task.needs_reconfiguration?
            end
            it "ignores models that have never been configured" do
                model = TaskContext.new_submodel
                task = syskit_stub_and_deploy(model)
                flexmock(model.configuration_manager).should_receive(:reload).once.
                    and_return(['default'])
                subject.reload_config
                assert !TaskContext.needs_reconfiguration?('stub')
            end
            it "does not redeploy the network" do
                model = TaskContext.new_submodel
                task = syskit_stub_deploy_and_configure(model)
                flexmock(model.configuration_manager).should_receive(:reload).once.
                    and_return(['default'])
                flexmock(Runtime).should_receive(:apply_requirement_modifications).never
                subject.reload_config
            end
        end

        describe "#restart_deployments" do
            attr_reader :task_m, :task
            before do
                @task_m = TaskContext.new_submodel
                @task = syskit_stub_deploy_configure_and_start(task_m.with_conf('default'))
                plan.add_mission_task(task)
                plug_apply_requirement_modifications
            end

            it "stops the matching deployments and redeploys" do
                subject.restart_deployments
                assert_event_emission plan.find_tasks(ShellInterface::ShellDeploymentRestart).first.stop_event
                assert task.finished?
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end

            it "restricts the deployments to the given models" do
                other_m = TaskContext.new_submodel
                other = syskit_stub_deploy_configure_and_start(other_m)
                subject.plan.add_mission_task(other)
                subject.restart_deployments(task.execution_agent.model)
                assert_event_emission plan.find_tasks(ShellInterface::ShellDeploymentRestart).first.stop_event
                assert task.finished?
                assert !other.finished?
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end

            it "accepts task models as argument" do
                other_m = TaskContext.new_submodel
                other = syskit_stub_deploy_configure_and_start(other_m)
                subject.plan.add_mission_task(other)
                subject.restart_deployments(task.model)
                assert_event_emission plan.find_tasks(ShellInterface::ShellDeploymentRestart).first.stop_event
                assert task.finished?
                assert !other.finished?
                assert_equal 1, plan.find_tasks(task_m).pending.to_a.size
            end
        end
    
        describe "#stop_deployments" do
            attr_reader :task_m, :task
            before do
                @task_m = TaskContext.new_submodel
                @task = syskit_stub_deploy_configure_and_start(task_m.with_conf('default'))
                plan.add_mission_task(task)
            end

            it "stops the matching deployments" do
                subject.stop_deployments
                assert_raises(Roby::MissionFailedError) do
                    assert_event_emission task.execution_agent.stop_event
                end
                assert task.finished?
            end

            it "restricts the deployments to the given models" do
                other = syskit_stub_deploy_configure_and_start(task_m.with_conf('other'))
                subject.plan.add_mission_task(other)
                subject.stop_deployments(task.execution_agent.model)
                # Deployment is asynchronous
                assert_raises(Roby::MissionFailedError) do
                    assert_event_emission task.execution_agent.stop_event
                end
                assert task.finished?
                assert !other.finished?
            end

            it "accepts task models as argument" do
                other_m = TaskContext.new_submodel
                other = syskit_stub_deploy_configure_and_start(other_m)
                subject.plan.add_mission_task(other)
                subject.stop_deployments(task.model)
                # Deployment is asynchronous
                assert_raises(Roby::MissionFailedError) do
                    assert_event_emission task.execution_agent.stop_event
                end
                assert task.finished?
                assert !other.finished?
            end
        end

        describe "the log group management" do
            attr_reader :group
            before do
                @group = Syskit.conf.logs.create_group 'test' do |g|
                    g.add /base.samples.frame.Frame/
                end
            end

            after do
                Syskit.conf.logs.remove_group('test')
            end

            it "enable_log_group enables the log group and redeploys" do
                group.enabled = false
                flexmock(subject).should_receive(:redeploy).once.ordered
                subject.enable_log_group 'test'
                assert group.enabled?
            end

            it "disable_log_group enables the log group and redeploys" do
                group.enabled = true
                flexmock(subject).should_receive(:redeploy).once.ordered
                subject.disable_log_group 'test'
                assert !group.enabled?
            end

            it "enable_log_group raises ArgumentError if the log group does not exist" do
                assert_raises(ArgumentError) do
                    subject.enable_log_group 'does_not_exist'
                end
            end

            it "disable_log_group raises ArgumentError if the log group does not exist" do
                assert_raises(ArgumentError) do
                    subject.disable_log_group 'does_not_exist'
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
                raise RuntimeError, "you must call #process_execute_call after a call to #queue_execute_call"
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

