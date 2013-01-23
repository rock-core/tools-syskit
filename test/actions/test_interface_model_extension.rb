require 'syskit/test'

describe Syskit::Actions::InterfaceModelExtension do
    include Syskit::SelfTest

    describe "#syskit_use_profile" do
        it "should export the profile definitions as actions" do
            req = flexmock
            req.should_receive(:to_instance_requirements).and_return(req)
            req.should_receive(:dup).and_return(req)
            actions = Class.new(Roby::Actions::Interface)
            profile = Syskit::Actions::Profile.new(nil)
            profile.define('def', req)
            actions.syskit_use_profile(profile)

            act = actions.find_action('def')
            assert act
            assert_equal req, act.requirements
        end
        it "should be so that the exported definitions can be used using the normal action interface" do
            actions = Class.new(Roby::Actions::Interface)
            profile = Syskit::Actions::Profile.new(nil)
            req = profile.define('def', Syskit::Component)
            actions.syskit_use_profile(profile)

            flexmock(req).should_receive(:as_plan).and_return(task = Roby::Task.new)
            act = actions.def.instanciate(plan)
            assert [task], plan.known_tasks.to_a
        end
    end
end

