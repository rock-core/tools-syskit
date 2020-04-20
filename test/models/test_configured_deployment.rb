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
            end
            describe "#orogen_model" do
                it "creates a new model with the name mappings applied" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(nil, deployment_m, "test" => "prefixed_test")
                    deployed_task = deployment.orogen_model.task_activities.first
                    assert_equal "prefixed_test", deployed_task.name
                    assert_equal task_m.orogen_model, deployed_task.context
                end
                it "does not touch the original model" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m = syskit_stub_deployment_model(task_m, "test")
                    deployment = ConfiguredDeployment.new(nil, deployment_m, "test" => "prefixed_test")
                    deployed_task = deployment_m.orogen_model.task_activities.first
                    assert_equal "test", deployed_task.name
                    assert_equal task_m.orogen_model, deployed_task.context
                end
            end
        end
    end
end
