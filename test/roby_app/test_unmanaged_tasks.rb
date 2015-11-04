require 'syskit/test/self'

module Syskit
    module RobyApp
        describe UnmanagedTasksManager do
            attr_reader :process_manager, :task_model, :unmanaged_task

            before do
                @task_model = Syskit::TaskContext.new_submodel
                @process_manager = Syskit.conf.process_server_for('unmanaged_tasks')
                Syskit.conf.use_unmanaged_task task_model => 'unmanaged_deployment_test'
            end

            after do
                if unmanaged_task
                    task = plan.find_tasks(Syskit::TaskContext).
                        with_arguments(orocos_name: unmanaged_task.name).
                        first
                    if task
                        process = task.execution_agent
                        if task.running?
                            assert_event_emission(task.stop_event) do
                                task.stop!
                            end
                        end
                        if process && process.running?
                            assert_event_emission(process.stop_event) do
                                process.stop!
                            end
                        end
                    end
                    unmanaged_task.dispose
                end
            end

            def create_unmanaged_task
                if @unmanaged_task
                    raise ArgumentError, "unmanaged task already created"
                end

                @unmanaged_task = Orocos::RubyTasks::TaskContext.from_orogen_model(
                    'unmanaged_deployment_test', task_model.orogen_model)
            end

            def delete_unmanaged_task
                unmanaged_task.dispose
                @unmanaged_task = nil
            end

            it "allows to deploy the unmanaged task" do
                syskit_deploy(task_model)
            end

            it "allows to kill a started deployment that was not ready" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.execution_agent.start_event) do
                    task.execution_agent.start!
                end
                assert_event_emission(task.execution_agent.stop_event) do
                    task.execution_agent.stop!
                end
            end

            it "configures and starts the task when it becomes available" do
                task = syskit_deploy(task_model)
                process_events
                assert task.execution_agent.running?
                assert !task.execution_agent.ready?

                ruby_task = nil
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
            end

            it "stopping the process causes the monitor thread to quit" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
                process_task = task.execution_agent
                monitor_thread = process_task.orocos_process.monitor_thread
                assert_event_emission(task.stop_event) do
                    task.stop!
                end
                assert !process_task.orocos_process.kill_thread.alive?
                assert !process_task.orocos_process.monitor_thread.alive?
                assert process_task.orocos_process.dead?
                assert !monitor_thread.alive?
            end

            it "aborts the execution agent if the spawn thread fails in unexpected ways" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.execution_agent.start_event)
                inhibit_fatal_messages do
                    assert_event_emission(task.execution_agent.stop_event) do
                        task.execution_agent.orocos_process.spawn_thread.raise RuntimeError
                    end
                end
            end

            it "aborts the execution agent if the monitor thread fails in unexpected ways" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.execution_agent.ready_event) do
                    create_unmanaged_task
                end
                inhibit_fatal_messages do
                    assert_event_emission(task.execution_agent.stop_event) do
                        task.execution_agent.orocos_process.monitor_thread.raise RuntimeError
                    end
                end
            end

            it "aborts the task if it becomes unavailable" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
                agent = task.execution_agent
                assert_event_emission(task.aborted_event) do
                    delete_unmanaged_task
                    # Synchronize on the monitor thread explicitely, otherwise
                    # the RTT state read might kick in first and bypass the
                    # whole purpose of the test
                    task.execution_agent.orocos_process.monitor_thread.join
                    assert task.execution_agent.orocos_process.dead?
                end
                assert agent.failed?
            end

            it "cleans up the tasks when killed" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
                assert_equal :RUNNING, unmanaged_task.rtt_state
                assert_event_emission(task.stop_event) do
                    task.execution_agent.stop!
                end
                assert_equal :PRE_OPERATIONAL, unmanaged_task.rtt_state
            end

            # This is really a heisentest .... previous versions of
            # UnmanagedProcess would fail when this happened but the current
            # implementation should be completely imprevious
            it "handles concurrently having the monitor fail and #kill being called" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
                inhibit_fatal_messages do
                    assert_event_emission(task.stop_event) do
                        delete_unmanaged_task
                        task.execution_agent.orocos_process.kill
                    end
                end
            end
        end
    end
end

