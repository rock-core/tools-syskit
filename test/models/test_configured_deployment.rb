# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe ConfiguredDeployment do
            describe "#new" do
                it "sets the deployment's 'on' argument" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new("stubs", deployment_m, "test" => "prefixed_test")
                    deployment_task = deployment.new
                    assert_equal "stubs", deployment_task.arguments[:on]
                end

                it "creates the deployment with read only" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(
                        "stubs", deployment_m, { "test" => "prefixed_test" },
                        read_only: true
                    )
                    deployment_task = deployment.new
                    assert_equal ["prefixed_test"], deployment_task.arguments[:read_only]
                end

                it "creates the deployment with read only using a pattern" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(
                        "stubs", deployment_m, { "test_task_name" => "prefixed_test" },
                        read_only: /fixed/
                    )
                    deployment_task = deployment.new
                    assert_equal ["prefixed_test"], deployment_task.arguments[:read_only]
                end

                it "raises when the read only task is not a valid deployment task name" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    e = assert_raises(ArgumentError) do
                        ConfiguredDeployment.new(
                            "stubs",
                            deployment_m,
                            { "test" => "prefixed_test" },
                            read_only: /stub/
                        )
                    end
                    assert_equal(
                        "#{[/stub/]} is not a valid deployed task name or "\
                        "pattern. The valid deployed task names are "\
                        "[\"prefixed_test\"].", e.message
                    )
                end
            end
            describe "#orogen_model" do
                it "creates a new model with the name mappings applied" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(nil, deployment_m, { "test" => "prefixed_test" })
                    deployed_task = deployment.orogen_model.task_activities.first
                    assert_equal "prefixed_test", deployed_task.name
                    assert_equal task_m.orogen_model, deployed_task.context
                end
                it "does not touch the original model" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(nil, deployment_m, { "test" => "prefixed_test" })
                    deployed_task = deployment_m.orogen_model.task_activities.first
                    assert_equal "test", deployed_task.name
                    assert_equal task_m.orogen_model, deployed_task.context
                end
            end
        end
    end
end
