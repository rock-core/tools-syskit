# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class BlockingHooksTests < Syskit::Test::ComponentTest
        run_live

        before do
            @orig_connect_timeout = Orocos::CORBA.connect_timeout
            @orig_call_timeout = Orocos::CORBA.call_timeout
            @orig_opportunistic_recovery =
                Syskit.conf.opportunistic_recovery_from_quarantine?
            @orig_auto_restart_flag =
                Syskit.conf.auto_restart_deployments_with_quarantines?
            @orig_exception_transition_timeout =
                Syskit.conf.exception_transition_timeout

            Orocos::CORBA.connect_timeout = 100
            Syskit.conf.opportunistic_recovery_from_quarantine = false
            Syskit.conf.auto_restart_deployments_with_quarantines = false
        end

        after do
            # This will "flush" all the pending waiting work
            #
            # Since we are killing stuff in the middle of execution, we
            # do expect some errors to show up. Sometimes. Othertimes,
            # the error will be reported by an EmissionFailed on `interrupt`
            plan.execution_engine.join_all_waiting_work

            Orocos::CORBA.connect_timeout = @orig_connect_timeout
            Orocos::CORBA.call_timeout = @orig_call_timeout
            Syskit.conf.opportunistic_recovery_from_quarantine =
                @orig_opportunistic_recovery
            Syskit.conf.auto_restart_deployments_with_quarantines =
                @orig_auto_restart_flag
            Syskit.conf.exception_transition_timeout =
                @orig_exception_transition_timeout
        end

        describe "system handling of blocking hooks" do
            attr_reader :task, :deployment

            before do
                @task_m = OroGen.orogen_syskit_tests.BlockingHooks
                                .deployed_as("blocking_hooks")
                @task = syskit_deploy(@task_m)
                @task.properties.time = 10
                @deployment = @task.execution_agent
                remove_logger
            end

            describe "#configure" do
                before do
                    @task.properties.hook = "configure"
                end

                it "waits for a long call to finish" do
                    @task.properties.time = 2
                    Orocos::CORBA.call_timeout = 5000
                    syskit_configure(@task)
                    assert_equal :STOPPED, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "marks a task whose call timed out as 'fatal' on the deployment" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1000
                    expect_execution.scheduler(true).timeout(5).to do
                        fail_to_start task
                    end
                    assert @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    start = Time.now

                    expect_execution.scheduler(true).join_all_waiting_work(false).to do
                        poll do
                            if task.setting_up? && (Time.now - start) > 1
                                kill_agent_once_in_poll(task)
                            end
                        end
                        fail_to_start task
                        emit deployment.kill_event
                    end
                end
            end

            describe "#start" do
                before do
                    @task.properties.hook = "start"
                    syskit_configure(@task)
                end

                it "waits for a long call to finish" do
                    @task.properties.time = 2
                    Orocos::CORBA.call_timeout = 5000
                    syskit_start(@task)
                    assert_equal :RUNNING, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "marks a task whose call timed out as 'fatal' on the deployment" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1000
                    expect_execution.scheduler(true).timeout(5).to do
                        fail_to_start task
                    end
                    assert @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    start = Time.now

                    expect_execution.scheduler(true).join_all_waiting_work(false).to do
                        poll do
                            if task.start_event.pending? && (Time.now - start) > 1
                                kill_agent_once_in_poll(task)
                            end
                        end
                        fail_to_start task
                        emit deployment.kill_event
                    end
                end
            end

            describe "#stop (blocking in update)" do
                before do
                    @task.properties.hook = "update"
                end

                after do
                    cleanup_running_tasks
                end

                it "waits for a long call to finish" do
                    @task.properties.time = 1
                    Orocos::CORBA.call_timeout = 4_000
                    syskit_configure_and_start(@task)

                    syskit_stop(@task)
                    assert_equal :STOPPED, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "quarantines a task whose call timed out" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1_000
                    syskit_configure(@task)

                    synchronize_on_sleep(task) { task.start! }

                    expect_execution { task.stop! }.timeout(5).to do
                        quarantine task
                    end
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "stops the task if the stop eventually works" do
                    Orocos::CORBA.call_timeout = 1_000
                    @task.properties.time = 4
                    syskit_configure(@task)

                    synchronize_on_sleep(task) { task.start! }

                    expect_execution { task.stop! }
                        .timeout(1.5).join_all_waiting_work(false)
                        .to { quarantine task }
                    expect_execution.to { emit task.stop_event }
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    syskit_configure(task)

                    synchronize_on_sleep(task) { task.start! }

                    start = Time.now
                    expect_execution { task.stop! }.join_all_waiting_work(false).to do
                        poll do
                            kill_agent_once_in_poll(task) if (Time.now - start) > 1
                        end
                        ignore_errors_from quarantine(task)
                        ignore_errors_from have_error_matching(
                            Roby::EmissionFailed
                            .match.with_origin(task.interrupt_event)
                        )
                        emit task.aborted_event
                        emit deployment.kill_event
                    end
                end
            end

            describe "#stop (blocking in stop)" do
                before do
                    @task.properties.hook = "stop"
                end

                after do
                    cleanup_running_tasks
                end

                it "waits for a long call to finish" do
                    @task.properties.time = 1
                    Orocos::CORBA.call_timeout = 4_000
                    syskit_configure_and_start(@task)

                    syskit_stop(@task)
                    assert_equal :STOPPED, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "quarantines a task whose call timed out" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1_000
                    syskit_configure_and_start(@task)

                    expect_execution { task.stop! }.timeout(5).to do
                        quarantine task
                    end
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "stops the task if the stop eventually works" do
                    Orocos::CORBA.call_timeout = 1_000
                    @task.properties.time = 4
                    syskit_configure_and_start(@task)

                    expect_execution { task.stop! }
                        .timeout(1.5).join_all_waiting_work(false)
                        .to { quarantine task }
                    expect_execution.to { emit task.stop_event }
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    syskit_configure_and_start(task)

                    start = Time.now
                    expect_execution { task.stop! }.join_all_waiting_work(false).to do
                        poll do
                            kill_agent_once_in_poll(task) if (Time.now - start) > 1
                        end
                        ignore_errors_from quarantine(task)
                        ignore_errors_from have_error_matching(
                            Roby::EmissionFailed
                            .match.with_origin(task.interrupt_event)
                        )
                        emit task.aborted_event
                        emit deployment.kill_event
                    end
                end
            end

            describe "#exception" do
                before do
                    @task.properties.hook = "exception"
                end

                after do
                    cleanup_running_tasks
                end

                it "waits for a long exception transition to finish" do
                    @task.properties.time = 1
                    Syskit.conf.exception_transition_timeout = 2
                    syskit_configure_and_start(@task)
                    expect_execution.to { emit task.exception_event }
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "quarantines a task whose transition to exception timed out" do
                    @task.properties.time = 10
                    Syskit.conf.exception_transition_timeout = 1
                    syskit_configure_and_start(@task)

                    expect_execution.timeout(5).to do
                        quarantine task
                    end
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "stops the task when it does stop" do
                    @task.properties.time = 4
                    Syskit.conf.exception_transition_timeout = 1
                    syskit_configure_and_start(@task)

                    expect_execution
                        .timeout(1.5).join_all_waiting_work(false)
                        .to { quarantine task }
                    expect_execution.to { emit task.exception_event }
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long transition" do
                    @task.properties.time = 10
                    Syskit.conf.exception_transition_timeout = 2
                    syskit_configure_and_start(task)

                    start = Time.now
                    expect_execution.join_all_waiting_work(false).to do
                        poll do
                            kill_agent_once_in_poll(task) if (Time.now - start) > 1
                        end
                        ignore_errors_from quarantine(task)
                        emit task.aborted_event
                        emit deployment.kill_event
                    end
                end
            end

            describe "#cleanup (reconfiguration)" do
                it "waits for a long call to finish" do
                    @task.properties.time = 2
                    Orocos::CORBA.call_timeout = 5000
                    prepare_cleanup
                    syskit_configure(@task)
                    assert_equal :STOPPED, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "marks a task whose call timed out as 'fatal' on the deployment" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1000
                    prepare_cleanup
                    expect_execution.scheduler(true).timeout(5).to do
                        fail_to_start task
                    end
                    assert @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    prepare_cleanup
                    start = Time.now

                    expect_execution.scheduler(true).join_all_waiting_work(false).to do
                        poll do
                            if task.setting_up? && (Time.now - start) > 1
                                kill_agent_once_in_poll(task)
                            end
                        end
                        fail_to_start task
                        emit deployment.kill_event
                    end
                end

                def prepare_cleanup
                    @task.properties.hook = "cleanup"
                    syskit_configure_and_start(@task)
                    syskit_stop(@task)
                    # trigger reconfiguration, but the `cleanup` hook will still see
                    # the old value
                    @task = syskit_deploy(@task_m)
                    remove_logger
                end
            end

            describe "#cleanup (after a property change in #configure)" do
                it "waits for a long call to finish" do
                    @task.properties.time = 2
                    Orocos::CORBA.call_timeout = 5000
                    prepare_cleanup
                    syskit_configure(@task)
                    assert_equal :STOPPED, rtt_state
                    refute @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "marks a task whose call timed out as 'fatal' on the deployment" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 1000
                    prepare_cleanup
                    expect_execution.scheduler(true).timeout(5).to do
                        fail_to_start task
                    end
                    assert @deployment.task_context_in_fatal?(@task.orocos_name)
                end

                it "handles the task being killed in the middle of a long call" do
                    @task.properties.time = 10
                    Orocos::CORBA.call_timeout = 2_000
                    prepare_cleanup
                    start = Time.now

                    expect_execution.scheduler(true).join_all_waiting_work(false).to do
                        poll do
                            if task.setting_up? && (Time.now - start) > 1
                                kill_agent_once_in_poll(task)
                            end
                        end
                        fail_to_start task
                        emit deployment.kill_event
                    end
                end

                def prepare_cleanup
                    time = @task.properties.time
                    @task.properties.hook = ""
                    syskit_configure(@task)
                    execute { plan.remove_task(@task) }
                    @task = syskit_deploy(@task_m)
                    @task.properties.hook = ""
                    @task.properties.time = time
                    def task.configure
                        super
                        properties.hook = "cleanup"
                    end
                    remove_logger
                end
            end
        end

        def trigger_fatal_error(task, &block)
            expect_execution { task.stop! }.to do
                emit task.fatal_error_event
                emit task.exception_event
                instance_eval(&block) if block
            end
        end

        def default_task_name
            "#{name}-#{Process.pid}"
        end

        def rtt_state(task = @task)
            Orocos.allow_blocking_calls { task.orocos_task.rtt_state }
        end

        def find_logger
            logger_m = Syskit::TaskContext.find_model_from_orogen_name("logger::Logger")
            plan.find_tasks(logger_m).first
        end

        def cleanup_running_tasks
            return unless @deployment.running?

            executed_tasks =
                deployment.each_executed_task.find_all(&:running?)
            expect_execution { deployment.kill! }
                .to do
                    emit deployment.kill_event
                    executed_tasks.each { |t| emit t.aborted_event }
                end
        end

        def synchronize_on_sleep(task, &block)
            expect_execution(&block).join_all_waiting_work(false).to do
                have_one_new_sample task.sleep_start_port
            end
        end

        def remove_logger
            execute do
                logger = find_logger
                plan.unmark_permanent_task(logger)
                plan.remove_task(logger)
            end
        end

        def kill_agent_once_in_poll(task)
            return unless (agent = task.execution_agent)
            return if agent.kill_event.pending?

            agent.kill!
        end
    end
end
