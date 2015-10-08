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
                assert_event_emission(task.stop_event) do
                    task.stop!
                end
                assert !process_task.orocos_process.monitor_thread.alive?
            end

            it "aborts the task if it becomes unavailable" do
                task = syskit_deploy(task_model)
                assert_event_emission(task.start_event) do
                    create_unmanaged_task
                end
                inhibit_fatal_messages do
                    assert_event_emission(task.aborted_event) do
                        delete_unmanaged_task
                    end
                end
            end
        end
    end
end
