require 'syskit/test'

describe Syskit::Actions::InterfaceModelExtension do
    include Syskit::SelfTest

    describe "#use_profile" do
        it "should export the profile definitions as actions" do
            req = flexmock
            req.should_receive(:dependency_injection_context).and_return(di = Syskit::DependencyInjectionContext.new)
            req.should_receive(:to_instance_requirements).and_return(req)
            req.should_receive(:dup).and_return(req)
            task_m = Syskit::TaskContext.new_submodel
            req.should_receive(:proxy_task_model).and_return(task_m)
            actions = Class.new(Roby::Actions::Interface)
            profile = Syskit::Actions::Profile.new(nil)
            profile.define('def', req)
            actions.use_profile(profile)

            act = actions.find_action_by_name('def_def')
            assert act
            assert_equal req, act.requirements
            assert_equal task_m, act.returned_type
        end
        it "should be so that the exported definitions can be used using the normal action interface" do
            actions = Class.new(Roby::Actions::Interface)
            profile = Syskit::Actions::Profile.new(nil)
            req = profile.define('def', Syskit::Component)
            actions.use_profile(profile)

            flexmock(req).should_receive(:as_plan).and_return(task = Roby::Task.new)
            act = actions.def_def.instanciate(plan)
            assert [task], plan.known_tasks.to_a
        end
    end
end

