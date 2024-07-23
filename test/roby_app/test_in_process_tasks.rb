# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module RobyApp
        describe InProcessTasksManager do
            attr_reader :deployment_task

            before do
                Syskit.conf.register_process_server(
                    "in_process_tasks", InProcessTasksManager.new
                )
                @process_manager = Syskit.conf.process_server_for("in_process_tasks")

                Roby.app.using_task_library "orogen_syskit_tests"
                @deployment_group = Syskit::Models::DeploymentGroup.new
            end

            after do
                if deployment_task&.running?
                    expect_execution { deployment_task.stop! }
                        .to { emit deployment_task.stop_event }
                end

                Syskit.conf.remove_process_server("in_process_tasks")
            end

            it "deploys a usable triggered task" do
                task = define_and_start(
                    OroGen.orogen_syskit_tests.TriggeredEcho => "some_name"
                )

                value =
                    expect_execution
                    .poll { syskit_write task.in_port, 10 }
                    .to { have_one_new_sample task.out_port }
                assert_equal 10, value
            end

            it "deploys a usable periodic task" do
                task = define_and_start(
                    OroGen.orogen_syskit_tests.PeriodicEcho => "some_name"
                )

                values =
                    expect_execution { syskit_write task.in_port, 10 }
                    .to { have_new_samples task.out_port, 10 }
                assert_equal [10] * 10, values
            end

            it "overrides the activity to a triggered task" do
                task = define_and_start(
                    OroGen.orogen_syskit_tests.PeriodicEcho => "some_name",
                    activity: { type: :triggered }
                )

                value =
                    expect_execution { syskit_write task.in_port, 10 }
                    .to { have_one_new_sample task.out_port }
                assert_equal 10, value

                expect_execution
                    .to { have_no_new_sample task.out_port, at_least_during: 0.5 }
            end

            it "overrides the activity to a slave task" do
                task = define_and_start(
                    OroGen.orogen_syskit_tests.PeriodicEcho => "some_name",
                    activity: { type: :slave }
                )

                expect_execution { syskit_write task.in_port, 10 }
                    .to { have_no_new_sample task.out_port, at_least_during: 0.5 }

                value =
                    expect_execution
                    .poll { task.orocos_task.execute }
                    .to { have_one_new_sample task.out_port }
                assert_equal 10, value
            end

            it "kills the task when shut down" do
                configured_deployment = @deployment_group.use_in_process_tasks(
                    OroGen.orogen_syskit_tests.Empty => "some_name"
                ).first

                plan.add(@deployment_task = configured_deployment.new)
                expect_execution { deployment_task.start! }
                    .to { emit deployment_task.ready_event }

                task = deployment_task.task("some_name")
                syskit_configure_and_start task
                orocos_task = task.orocos_task

                expect_execution { task.stop! }
                    .to { emit task.stop_event }

                # orocos_task should still be valid
                Orocos.allow_blocking_calls { orocos_task.ping }
                expect_execution { deployment_task.stop! }
                    .to { emit deployment_task.stop_event }

                assert_raises(Orocos::ComError) do
                    Orocos.allow_blocking_calls { orocos_task.ping }
                end
            end

            def create_deployment(**spec)
                configured_deployment =
                    @deployment_group.use_in_process_tasks(**spec).first

                plan.add(@deployment_task = configured_deployment.new)
                @deployment_task
            end

            def define_and_start(**spec)
                deployment_task = create_deployment(**spec)
                expect_execution { deployment_task.start! }
                    .to { emit deployment_task.ready_event }

                task = deployment_task.task("some_name")
                syskit_configure_and_start task

                task
            end
        end
    end
end
