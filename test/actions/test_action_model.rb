require 'syskit/test/self'

describe Syskit::Actions::Models::Action do
    describe "droby marshalling" do
        attr_reader :interface_m, :requirements, :action_m, :task_m, :reloaded
        before do
            @interface_m = Class.new(Roby::Actions::Interface)
            @requirements = Syskit::InstanceRequirements.new([@task_m = Syskit::TaskContext.new_submodel])
            @action_m = Syskit::Actions::Models::Action.new(interface_m, requirements)
            @reloaded = Marshal.load(Marshal.dump(action_m.droby_dump(nil))).proxy(Roby::Distributed::DumbManager)
        end

        it "should be able to be marshalled and unmarshalled" do
            assert_equal reloaded.action_interface_model, action_m.action_interface_model
        end
        it "can marshal even if the requirements cannot" do
            assert_raises(TypeError) { Marshal.dump(requirements) }
            refute_kind_of DRb::DRbUnknown, reloaded
        end
        it "passes along the returned type" do
            assert_equal task_m, reloaded.returned_type
        end
    end

    describe "#plan_pattern" do
        it "adds the arguments to the underlying instance requirement object" do
            req = Syskit::InstanceRequirements.new
            action_m = Syskit::Actions::Models::Action.new(nil, req)
            plan.add(task = action_m.plan_pattern(test: 10))
            assert_equal 10, task.arguments[:test]
            assert_equal Hash[test: 10], task.planning_task.requirements.arguments
        end
        it "sets the job ID on the planning task" do
            req = Syskit::InstanceRequirements.new
            action_m = Syskit::Actions::Models::Action.new(nil, req)
            plan.add(task = action_m.plan_pattern(:job_id => 20, test: 10))
            assert_equal 20, task.planning_task.job_id
        end
        it "does not set the job ID at all if not given" do
            req = Syskit::InstanceRequirements.new
            action_m = Syskit::Actions::Models::Action.new(nil, req)
            plan.add(task = action_m.plan_pattern)
            # Will raise if already set, even if set to nil
            task.planning_task.job_id = 10
        end
    end

    describe "#run" do
        attr_reader :req, :action_m, :interface
        before do
            @req = Syskit::InstanceRequirements.new
            @action_m = Syskit::Actions::Models::Action.new(nil, req)
            @interface = flexmock(:plan => plan)
        end
        it "adds the task to the interface's plan" do
            task = action_m.run(interface, test: 10)
            assert plan.include?(task)
        end
        it "adds the arguments to the underlying instance requirement object" do
            task = action_m.run(interface, test: 10)
            assert_equal 10, task.arguments[:test]
            assert_equal Hash[test: 10], task.planning_task.requirements.arguments
        end
    end
end


