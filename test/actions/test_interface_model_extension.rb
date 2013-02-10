require 'syskit/test'

describe Syskit::Actions::InterfaceModelExtension do
    include Syskit::SelfTest

    describe "#use_profile" do
        attr_reader :actions, :profile
        before do
            @actions = Class.new(Roby::Actions::Interface)
            @profile = Syskit::Actions::Profile.new(nil)
        end

        it "should export the profile definitions as actions" do
            req = flexmock
            req.should_receive(:to_instance_requirements).and_return(req)
            req.should_receive(:dup).and_return(req)
            profile.define('def', req)
            actions.use_profile(profile)

            act = actions.find_action('def')
            assert act
            assert_equal req, act.requirements
        end

        it "should be so that the exported definitions can be used using the normal action interface" do
            req = profile.define('def', Syskit::Component)
            actions.use_profile(profile)

            flexmock(req).should_receive(:as_plan).and_return(task = Roby::Task.new)
            act = actions.def.instanciate(plan)
            assert [task], plan.known_tasks.to_a
        end

        it "should make task arguments that do not have a default a required argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert arg.required
        end

        it "should make task arguments that do have a default an optional argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, :default => nil }
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert !arg.required
        end

        it "should make task arguments that do not have a default but are selected in the instance requirements an optional argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m.with_arguments('arg0' => nil))
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert !arg.required
        end

        it "should pass the action arguments to the instanciated task context" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)
            act = actions.def_def.instanciate(plan, 'arg0' => 10)
            assert_equal 10, act.arg0
        end
    end
end

