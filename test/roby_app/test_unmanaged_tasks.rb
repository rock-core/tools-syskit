require 'syskit/test/self'

module Syskit
    module RobyApp
        describe UnmanagedTasksManager do
            attr_reader :process_manager, :task_model, :unmanaged_task, :deployment_task

            before do
                @task_model = Syskit::TaskContext.new_submodel
                @process_manager = Syskit.conf.process_server_for('unmanaged_tasks')
                Syskit.conf.use_unmanaged_task task_model => 'unmanaged_deployment_test'
                task = syskit_deploy(task_model)
                @deployment_task = task.execution_agent
                plan.remove_task(task)
            end

            after do
                plan.unmark_permanent_task(deployment_task)
                if deployment_task.running?
                    assert_event_emission(deployment_task.stop_event) do
                        deployment_task.stop!
                    end
                end

                if unmanaged_task
                    unmanaged_task.dispose
                end
            end

            def create_unmanaged_task
                if @unmanaged_task
                    raise ArgumentError, "unmanaged task already created"
                end

                @unmanaged_task = Orocos.allow_blocking_calls do
                    Orocos::RubyTasks::TaskContext.from_orogen_model(
                        'unmanaged_deployment_test', task_model.orogen_model)
                end
            end

            def make_deployment_ready
                plan.add_permanent_task(deployment_task)
                assert_event_emission(deployment_task.ready_event) do
                    create_unmanaged_task
                    deployment_task.start!
                end
            ensure
                plan.unmark_permanent_task(deployment_task)
            end

            def delete_unmanaged_task
                unmanaged_task.dispose
                @unmanaged_task = nil
            end

            it "sets the deployment's process name's to the specified name" do
                assert_equal "unmanaged_deployment_test", deployment_task.process_name
            end

            it "readies the execution agent when the task becomes available" do
                plan.add_permanent_task(deployment_task)
                deployment_task.start!
                assert deployment_task.running?
                refute deployment_task.ready?

                assert_event_emission(deployment_task.ready_event) do
                    create_unmanaged_task
                end
                task = deployment_task.task('unmanaged_deployment_test')
                assert_equal unmanaged_task, task.orocos_task
            end

            it "stopping the process causes the monitor thread to quit" do
                make_deployment_ready
                monitor_thread = deployment_task.orocos_process.monitor_thread
                assert_event_emission(deployment_task.stop_event) do
                    deployment_task.stop!
                end
                refute deployment_task.orocos_process.monitor_thread.alive?
                assert deployment_task.orocos_process.dead?
                refute monitor_thread.alive?
            end


            it "allows to kill a started deployment that was not ready" do
                expect_execution { deployment_task.start! }.
                    with_setup { join_all_waiting_work false }.
                    to { emit deployment_task.start_event }
                expect_execution { deployment_task.stop! }.
                    with_setup { join_all_waiting_work false }.
                    to { emit deployment_task.stop_event }
            end

            it "allows to kill a deployment that is ready" do
                make_deployment_ready
                assert_event_emission(deployment_task.stop_event) do
                    deployment_task.stop!
                end
            end

            it "aborts the execution agent if the monitor thread fails in unexpected ways" do
                make_deployment_ready
                messages = capture_log(deployment_task.orocos_process, :fatal) do
                    assert_event_emission(deployment_task.stop_event) do
                        deployment_task.orocos_process.monitor_thread.raise RuntimeError
                    end
                end
                assert_equal ["assuming #{deployment_task.orocos_process} died because the background thread died with",
                              "RuntimeError (RuntimeError)"], messages
            end

            it "deregisters the process object of the process whose thread failed" do
                make_deployment_ready
                process = deployment_task.orocos_process
                process_manager = process.process_manager
                begin
                    flexmock(process).should_receive(:verify_threads_state).and_raise(RuntimeError)
                    capture_log(process, :fatal) do
                        assert_equal [process], process_manager.wait_termination(0).to_a
                        assert_equal Set[], process_manager.wait_termination(0)
                    end
                ensure process_manager.processes['unmanaged_deployment_test'] = process
                end
            end

            it "stops the deployment if the remote task becomes unavailable" do
                make_deployment_ready
                messages = capture_log(deployment_task, :warn) do
                    assert_event_emission(deployment_task.failed_event) do
                        delete_unmanaged_task
                        # Synchronize on the monitor thread explicitely, otherwise
                        # the RTT state read might kick in first and bypass the
                        # whole purpose of the test
                        deployment_task.orocos_process.monitor_thread.join
                        assert deployment_task.orocos_process.dead?
                    end
                end
                assert_equal ["unmanaged_deployment_test unexpectedly died on process server unmanaged_tasks"],
                    messages
            end

            # This is really a heisentest .... previous versions of
            # UnmanagedProcess would fail when this happened but the current
            # implementation should be completely imprevious
            it "handles concurrently having the monitor fail and #kill being called" do
                make_deployment_ready
                assert_event_emission(deployment_task.stop_event) do
                    delete_unmanaged_task
                    deployment_task.orocos_process.kill
                end
            end
        end
    end
end

