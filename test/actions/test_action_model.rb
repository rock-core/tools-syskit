require 'syskit/test'

describe Syskit::Actions::ActionModel do
    include Syskit::SelfTest

    describe "droby marshalling" do
        attr_reader :interface_m, :requirements, :action_m, :task_m, :reloaded
        before do
            @interface_m = Class.new(Roby::Actions::Interface)
            @requirements = Syskit::InstanceRequirements.new([@task_m = Syskit::TaskContext.new_submodel])
            @action_m = Syskit::Actions::ActionModel.new(interface_m, requirements)
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
end


