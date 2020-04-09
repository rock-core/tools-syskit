# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module RobyApp
        describe LoggingGroup do
            attr_reader :task_m, :deployment_m

            before do
                task_m = @task_m = Syskit::TaskContext.new_submodel(name: "TestTask") do
                    output_port "out", "/double"
                end
                @deployment_m = Syskit::Deployment.new_submodel(name: "TestDeployment") do
                    task "task", task_m.orogen_model
                end
            end

            subject { LoggingGroup.new }

            describe "#add" do
                it "raises ArgumentError if given a unknown model type" do
                    assert_raises(ArgumentError) do
                        subject.add Class.new
                    end
                end
                it "raises ArgumentError if given a plain object that cannot match strings" do
                    fake = flexmock
                    fake.should_receive(:===).and_raise(Exception.new("failed to match"))
                    assert_raises(ArgumentError) do
                        subject.add fake
                    end
                end
            end

            describe "#matches_name?" do
                it "does not match by default" do
                    assert !subject.matches_name?("NotMatching")
                end
                it "matches strings by equality" do
                    subject.add "Test"
                    assert subject.matches_name?("Test")
                end
                it "matches names by ===" do
                    subject.add /Test/
                    assert subject.matches_name?("AnotherTestReally")
                end
            end

            describe "#matches_deployment?" do
                let(:deployment) do
                    plan.add(deployment = deployment_m.new)
                    deployment
                end

                it "does not match a deployment by default" do
                    assert !subject.matches_deployment?(deployment)
                end
                it "matches a deployment by its model" do
                    subject.add deployment_m
                    assert subject.matches_deployment?(deployment)
                end
                it "matches a deployment by its name" do
                    subject.add "TestDeployment"
                    assert subject.matches_deployment?(deployment)
                end
            end

            describe "#matches_type?" do
                let :type_m do
                    registry = Typelib::Registry.new
                    registry.create_compound "/TestType"
                end
                it "does not match by default" do
                    assert !subject.matches_type?(type_m)
                end

                it "matches a type by its model" do
                    subject.add type_m
                    assert subject.matches_type?(type_m)
                end
                it "matches a type by its name" do
                    subject.add /Test/
                    assert subject.matches_type?(type_m)
                end
            end

            describe "#matches_task?" do
                let(:task) do
                    plan.add(task = task_m.new(orocos_name: "test_task"))
                    task.executed_by(deployment_m.new)
                    task
                end

                it "does not match by default" do
                    assert !subject.matches_task?(task)
                end
                it "matches a task by its model" do
                    subject.add task_m
                    assert subject.matches_task?(task)
                end
                it "matches a task by its deployment" do
                    subject.add deployment_m
                    assert subject.matches_task?(task)
                end
                it "handles tasks without deployments" do
                    task.remove_execution_agent(task)
                    assert !subject.matches_task?(task)
                end
                it "matches a task by its name" do
                    subject.add "test_task"
                    assert subject.matches_task?(task)
                end
            end

            describe "#matches_port?" do
                let :port do
                    plan.add(task = task_m.new(orocos_name: "test_task"))
                    task.executed_by(deployment_m.new)
                    task.out_port
                end

                it "does not match by default" do
                    assert !subject.matches_port?(port)
                end
                it "matches a port by its model" do
                    subject.add task_m.out_port
                    assert subject.matches_port?(port)
                end
                it "matches a superclass port" do
                    subclass_m = task_m.new_submodel
                    plan.add(subclass = subclass_m.new)
                    subject.add task_m.out_port
                    assert subject.matches_port?(subclass.out_port)
                end
                it "matches a port by its name" do
                    subject.add "out"
                    assert subject.matches_port?(port)
                end
                it "matches a port by its type" do
                    flexmock(subject).should_receive(:matches_type?)
                                     .with(port.type).and_return(true)
                    assert subject.matches_port?(port)
                end
                it "matches a port by its task" do
                    flexmock(subject).should_receive(:matches_task?)
                                     .with(port.component).and_return(true)
                    assert subject.matches_port?(port)
                end
                it "matches a port by its deployment" do
                    flexmock(subject).should_receive(:matches_deployment?)
                                     .with(port.component.execution_agent).and_return(true)
                    assert subject.matches_port?(port)
                end
            end
        end
    end
end
