require 'syskit/test/self'

describe Syskit::TaskContext do
    describe "#initialize" do
        it "sets up the task object to be non-executable" do
            plan.add(task = Syskit::ROS::Node.new_submodel.new(orocos_name: "bla", conf: []))
            assert !task.executable?
            # Verify that the task is indeed non-executable because the flag is
            # already set
            task.executable = nil
            assert task.executable?
        end
    end
end

