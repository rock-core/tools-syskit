# frozen_string_literal: true

using_task_library "logger"
using_task_library "orogen_syskit_tests"

module Syskit
    class StateReaderDisconnectionTests < Syskit::Test::ComponentTest
        run_live

        attr_reader :task, :deployment

        before do
            @orig_connect_timeout = Orocos::CORBA.connect_timeout
            @orig_call_timeout = Orocos::CORBA.call_timeout
            @orig_opportunistic_recovery =
                Syskit.conf.opportunistic_recovery_from_quarantine?
            @orig_auto_restart_flag =
                Syskit.conf.auto_restart_deployments_with_quarantines?

            Orocos::CORBA.connect_timeout = 100
            Syskit.conf.opportunistic_recovery_from_quarantine = false
            Syskit.conf.auto_restart_deployments_with_quarantines = false

            @task_m = OroGen.orogen_syskit_tests.BlockingHooks
                            .deployed_as("blocking_hooks")
            @task = syskit_deploy(@task_m)
            Orocos::CORBA.call_timeout = 5000
            @task.properties.time = 2
            @deployment = @task.execution_agent
            remove_logger
        end

        after do
            Orocos::CORBA.connect_timeout = @orig_connect_timeout
            Orocos::CORBA.call_timeout = @orig_call_timeout
            Syskit.conf.opportunistic_recovery_from_quarantine =
                @orig_opportunistic_recovery
            Syskit.conf.auto_restart_deployments_with_quarantines =
                @orig_auto_restart_flag
        end

        describe "when losing the state reader while configuring" do
            it "quarantines the task" do
                task.properties.hook = "configure"
                syskit_start_execution_agents(task)
                expect_execution.scheduler(true).join_all_waiting_work(false).to do
                    have_one_new_sample task.sleep_start_port
                end
                expect_execution { task.state_reader.disconnect }
                    .to { quarantine(task) }

                assert task.setup?
            end
        end

        describe "when losing the state reader while starting" do
            before do
                task.properties.hook = "start"
                syskit_configure(task)
                synchronize_on_sleep(task, execute: -> { task.start! })
            end

            it "goes into quarantine and falls back to the remote state getter" do
                expect_execution { task.state_reader.disconnect }
                    .to do
                        quarantine(task)
                        emit task.start_event
                    end

                syskit_stop(task)
            end

            it "does nothing more if the remote getter is lost as well" do
                mock_disconnected_remote_state_getter
                expect_execution { task.state_reader.disconnect }
                    .join_all_waiting_work(false)
                    .to do
                        quarantine task
                        fail_to_start task
                    end

                deployment_kill
            end
        end

        describe "when losing the state reader while running" do
            before do
                task.properties.hook = "update"
                syskit_configure(task)
                synchronize_on_sleep(
                    task,
                    execute: -> { task.start! },
                    predicates: ->(_) { emit task.start_event }
                )
            end

            it "goes into quarantine, falls back to the remote state getter and "\
               "attempts to stop the task" do
                expect_execution { task.state_reader.disconnect }
                    .to do
                        quarantine(task)
                        emit task.stop_event
                    end
            end

            it "does nothing more if the remote getter is lost as well" do
                mock_disconnected_remote_state_getter
                # Inhibit the stop call ... or we have a race
                flexmock(task).should_receive(:queue_last_chance_to_stop)
                expect_execution { task.state_reader.disconnect }
                    .join_all_waiting_work(false)
                    .to { quarantine task }

                sleep 2.5
                expect_execution.to { not_emit task.stop_event }

                deployment_kill
            end
        end

        describe "when losing the state reader while stopping" do
            before do
                @task.properties.hook = "stop"
                syskit_configure_and_start(@task)
                synchronize_on_sleep(task, execute: -> { task.stop! })
            end

            it "goes into quarantine and falls back to the remote state getter" do
                expect_execution { task.state_reader.disconnect }
                    .to do
                        quarantine(task)
                        emit task.stop_event
                    end
            end

            it "does nothing more if the remote getter is lost as well" do
                mock_disconnected_remote_state_getter
                expect_execution { task.state_reader.disconnect }
                    .join_all_waiting_work(false)
                    .to { quarantine task }

                sleep 2.5
                expect_execution.to { not_emit task.stop_event }

                deployment_kill
            end
        end

        describe "when losing the state reader while processing an exception" do
            before do
                @task.properties.hook = "exception"
                syskit_configure(@task)
                synchronize_on_sleep(task, execute: -> { task.start! })
            end

            it "goes into quarantine and falls back to the remote state getter" do
                expect_execution { task.state_reader.disconnect }
                    .to do
                        quarantine(task)
                        emit task.exception_event
                    end
            end

            it "does nothing more if the remote getter is lost as well" do
                mock_disconnected_remote_state_getter
                expect_execution { task.state_reader.disconnect }
                    .join_all_waiting_work(false)
                    .to { quarantine task }

                sleep 2.5
                expect_execution.to { not_emit task.stop_event }

                deployment_kill
            end
        end

        describe "when only losing the remote state reader "\
                 "while processing an exception" do
            before do
                @task.properties.hook = "exception"
                syskit_configure(@task)
                synchronize_on_sleep(task, execute: -> { task.start! })
            end

            it "goes into quarantine and processes the exception normally" do
                mock_disconnected_remote_state_getter
                expect_execution.join_all_waiting_work(false).to { quarantine(task) }

                sleep 2.5
                expect_execution.to { emit task.stop_event }
            end
        end

        def mock_disconnected_remote_state_getter
            task_info = task.execution_agent.remote_task_handles[task.orocos_name]
            flexmock(task_info.state_getter)
                .should_receive(:connected?).and_return(false)
        end

        def synchronize_on_sleep(task, execute: ->(_) {}, predicates: ->(_) {})
            expect_execution(&execute).join_all_waiting_work(false).to do
                have_one_new_sample task.sleep_start_port
                instance_eval(&predicates)
            end
        end

        def find_logger
            logger_m = Syskit::TaskContext.find_model_from_orogen_name("logger::Logger")
            plan.find_tasks(logger_m).first
        end

        def remove_logger
            execute do
                logger = find_logger
                plan.unmark_permanent_task(logger)
                plan.remove_task(logger)
            end
        end

        def deployment_kill # rubocop:disable Metrics/AbcSize
            expect_execution { task.execution_agent.stop! }
                .to do
                    emit task.execution_agent.stop_event
                    emit task.aborted_event if task.running?
                    ignore_errors_from quarantine(task)
                end
        end
    end
end
