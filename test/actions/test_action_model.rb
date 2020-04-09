# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Actions::Models::Action do
    describe "#rebind" do
        attr_reader :task_m, :profile_m, :interface_m
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @profile_m = Syskit::Actions::Profile.new
            profile_m.define "test", task_m
            @interface_m = Roby::Actions::Interface.new_submodel
            interface_m.use_profile profile_m
        end

        it "maps a definition-based action overloaded into a method-based one" do
            action = interface_m.find_action_by_name("test_def")

            subclass_m = interface_m.new_submodel
            subclass_m.describe "test_def"
            subclass_m.send(:define_method, "test_def") {}
            assert_equal subclass_m.find_action_by_name("test_def"),
                         action.rebind(subclass_m)
        end
        it "maps a definition-based action that got overloaded by another" do
            action = interface_m.find_action_by_name("test_def")

            subtask_m = task_m.new_submodel
            subprofile_m = Syskit::Actions::Profile.new
            subprofile_m.define "test", subtask_m
            subinterface_m = Roby::Actions::Interface.new_submodel
            subinterface_m.use_profile subprofile_m
            new_action = subinterface_m.find_action_by_name("test_def")

            assert_equal new_action, action.rebind(subinterface_m)
        end
    end

    describe "droby marshalling" do
        attr_reader :interface_m, :requirements, :action_m, :task_m
        before do
            @interface_m = Class.new(Roby::Actions::Interface)
            @task_m = Syskit::TaskContext.new_submodel(name: "DRobyMarshallingTest")
            @requirements = Syskit::InstanceRequirements.new([task_m])
            @action_m = Syskit::Actions::Models::Action.new(requirements)
        end

        it "should be able to be marshalled and unmarshalled" do
            assert_droby_compatible(action_m)
        end
        it "can marshal even if the requirements cannot" do
            assert_raises(TypeError) { Marshal.dump(requirements) }
            assert_droby_compatible(action_m)
        end
        it "passes along the requirements name, model and arguments" do
            requirements.name = "bla_def"
            requirements.with_arguments(test: 10, other: flexmock(droby_dump: 20))

            remote_marshaller = Roby::DRoby::Marshal.new
            reloaded = assert_droby_compatible(action_m, remote_marshaller: remote_marshaller)
            reloaded_task_m = remote_marshaller.object_manager.find_model_by_name("DRobyMarshallingTest")
            assert_equal reloaded_task_m, reloaded.returned_type
            assert_equal reloaded_task_m, reloaded.requirements.model
            assert_equal "bla_def", reloaded.requirements.name
            assert_equal Hash[test: 10, other: 20], reloaded.requirements.arguments
        end
        it "passes along the returned type" do
            remote_marshaller = Roby::DRoby::Marshal.new
            reloaded = assert_droby_compatible(action_m, remote_marshaller: remote_marshaller)
            assert_equal remote_marshaller.object_manager.find_model_by_name("DRobyMarshallingTest"), reloaded.returned_type
        end
    end

    describe "#plan_pattern" do
        attr_reader :req, :action_m
        before do
            @req = Syskit::InstanceRequirements.new
            @action_m = Syskit::Actions::Models::Action.new(req)
        end
        it "adds the arguments to the underlying instance requirement object" do
            task = action_m.plan_pattern(test: 10)
            assert_equal 10, task.arguments[:test]
            assert_equal Hash[test: 10], task.planning_task.requirements.arguments
        end
        it "sets the job ID on the planning task" do
            task = action_m.plan_pattern(job_id: 20, test: 10)
            assert_equal 20, task.planning_task.job_id
        end
        it "does not pass the job ID argument to the action" do
            task = action_m.plan_pattern(job_id: 20, test: 10)
            assert_equal Hash[test: 10], task.planning_task.action_arguments
        end
        it "does not set the job ID at all if not given" do
            task = action_m.plan_pattern
            # Will raise if already set, even if set to nil
            task.planning_task.job_id = 10
        end
    end

    describe "#run" do
        attr_reader :req, :action_m, :interface
        before do
            @req = Syskit::InstanceRequirements.new
            @action_m = Syskit::Actions::Models::Action.new(req)
            @interface = flexmock(plan: plan)
        end
        it "adds the task to the interface's plan" do
            task = action_m.run(interface, test: 10)
            assert plan.has_task?(task)
        end
        it "adds the arguments to the underlying instance requirement object" do
            task = action_m.run(interface, test: 10)
            assert_equal 10, task.arguments[:test]
            assert_equal Hash[test: 10], task.planning_task.requirements.arguments
        end
    end

    describe "#method_missing" do
        attr_reader :req, :action_m
        before do
            req = Syskit::InstanceRequirements.new
            @action_m = Syskit::Actions::Models::Action.new(req)
        end
        it "allows to derive new actions using the InstanceRequirements API" do
            new_action_m = action_m.with_arguments(test: 10)
            assert_equal Hash[test: 10], new_action_m.requirements.arguments
        end
        it "propagates the original actionn documentation" do
            action_m.doc = "test documentation"
            new_action_m = action_m.with_arguments(test: 10)
            assert_equal "test documentation", new_action_m.doc
        end
        it "does not modify the original action" do
            action_m.with_arguments(test: 10)
            assert_equal Hash[], action_m.requirements.arguments
        end
    end
end
