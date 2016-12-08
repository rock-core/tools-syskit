require 'syskit/test/self'

describe Syskit::Actions::InterfaceModelExtension do
    describe "#use_profile" do
        attr_reader :actions, :profile
        before do
            @actions = Class.new(Roby::Actions::Interface)
            @profile = Syskit::Actions::Profile.new(nil)
        end

        it "should export the profile definitions as actions" do
            task_m = Syskit::TaskContext.new_submodel
            req = task_m.to_instance_requirements
            actions = Roby::Actions::Interface.new_submodel
            profile = Syskit::Actions::Profile.new(nil)
            profile.define('def', task_m)
            actions.use_profile(profile)

            act = actions.find_action_by_name('def_def')
            assert act
            assert_equal req, act.requirements
            assert_equal task_m, act.returned_type
        end

        it "should be so that the exported definitions can be used using the normal action interface" do
            req = profile.define('def', Syskit::Component)
            actions.use_profile(profile)

            flexmock(req).should_receive(:as_plan).and_return(task = Roby::Task.new)
            act = actions.def_def.instanciate(plan)
            assert [task], plan.tasks.to_a
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

        it "should not make arguments of Composition arguments of the action" do
            task_m = Syskit::Composition.new_submodel
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            assert action.arguments.empty?
        end

        it "should not make arguments of TaskContext arguments of the action" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            assert action.arguments.empty?
        end

        it "should make task arguments that do have a default an optional argument of the action model" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, default: nil }
            profile.define('def', task_m)
            actions.use_profile(profile)
            action = actions.find_action_by_name('def_def')

            arg = action.arguments.first
            assert_equal 'arg0', arg.name
            assert !arg.required
        end

        it "should not require arguments to be given to the newly defined action method if there are no required arguments" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, default: nil }
            profile.define('test', task_m)
            actions.use_profile(profile)
            act = actions.new(plan)
            plan.add(act.test_def)
        end

        it "should accept to be given argument to the newly defined action method even if there are no required arguments" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0, default: nil }
            profile.define('test', task_m)
            actions.use_profile(profile)
            act = actions.new(plan)
            plan.add(task = act.test_def(arg0: 10).as_plan)
            assert_equal Hash[arg0: 10], task.planning_task.requirements.arguments
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

        it "should pass the action arguments to the instanciated task context when Action#instanciate is called" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)
            act = actions.def_def.instanciate(plan, 'arg0' => 10)
            assert_equal 10, act.arg0
        end

        it "should pass the action arguments to the instanciated task context when the generated action method is called" do
            task_m = Syskit::TaskContext.new_submodel { argument :arg0 }
            profile.define('def', task_m)
            actions.use_profile(profile)

            actions = self.actions.new(plan)
            plan.add(act = actions.def_def(arg0: 10).as_plan)
            assert_equal 10, act.arg0
        end
    end

    describe "the generated action method" do
        attr_reader :actions, :profile
        before do
            @actions = Roby::Actions::Interface.new_submodel
            @profile = Syskit::Actions::Profile.new(nil)
        end

        def call_action_method(*arguments, &block)
            task_m = Syskit::TaskContext.new_submodel(&block)
            profile.define('test', task_m)
            actions.use_profile(profile)
            task = actions.new(plan).test_def(*arguments)
            plan.add(task = task.as_plan)
            return task_m, task
        end

        it "should return a plan pattern whose requirements are the definition's" do
            task_m, task = call_action_method
            assert_equal task_m, task.planning_task.requirements.model
        end
        it "should return the updated requirements if called from a submodel" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define('test', task_m)
            subprofile = Syskit::Actions::Profile.new(nil)
            task_m = task_m.new_submodel
            subprofile.use_profile profile
            subprofile.define('test', task_m)

            actions.use_profile(subprofile)
            task = actions.new(plan).test_def.as_plan
            plan.add(task)
            assert_equal task_m, task.planning_task.requirements.model
        end
        it "should allow passing arguments if the main model has some" do
            task_m, task = call_action_method(arg0: 10) { argument :arg0 }
            assert_equal Hash[arg0: 10], task.planning_task.requirements.arguments
        end
        it "should require passing arguments if the main model has some without defaults" do
            task_m = Syskit::TaskContext.new_submodel do
                argument :arg0
                argument :with_defaults, default: nil
            end
            profile.define('test', task_m)
            actions.use_profile(profile)
            assert_raises(ArgumentError) { actions.new(plan).test_def }
        end
        it "should allow calling without arguments if the task has defaults" do
            task_m = Syskit::TaskContext.new_submodel do
                argument :arg0, default: 10
            end
            profile.define('test', task_m)
            actions.use_profile(profile)
            task = actions.new(plan).test_def.as_plan
            plan.add(task)
            assert_equal Hash[], task.planning_task.requirements.arguments
        end
        it "precomputes the requirements template the first time" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define 'test', task_m
            actions.use_profile(profile)
            from_method = actions.new(plan).test_def
            refute_nil from_method.template
        end
        it "does not recompute an existing template" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define 'test', task_m
            actions.use_profile(profile)
            actions.new(plan).test_def
            flexmock(actions.find_action_by_name('test_def').requirements).should_receive(:compute_template).never
            actions.new(plan).test_def
        end
        it "shares a precomputed template with the action object" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define 'test', task_m
            actions.use_profile(profile)
            from_object = actions.find_action_by_name('test_def').to_instance_requirements
            from_method = actions.new(plan).test_def
            assert_same from_object.template, from_method.template
        end
    end

    describe "overloading of definitions by actions" do
        attr_reader :actions, :profile
        before do
            @actions = Roby::Actions::Interface.new_submodel
            @profile = Syskit::Actions::Profile.new(nil)
        end

        it "allows overloading a profile-defined action with a method-based one" do
            task_m = Syskit::TaskContext.new_submodel
            profile.define('test', task_m)
            actions.use_profile(profile)
            recorder = flexmock
            recorder.should_receive(:called).once
            actions.class_eval do
                describe 'test'
                define_method(:test_def) { recorder.called; super() }
            end
            plan.add(actions.new(plan).test_def)
        end

        it "provides an easy way to change the requirements in the overloaded action methods" do
            srv_m = Syskit::DataService.new_submodel(name: 'Srv')
            task_m = Syskit::TaskContext.new_submodel(name: 'Task')
            task_m.provides srv_m, as: 'test'
            deployed_task_m = syskit_stub_requirements(task_m)
            cmp_m = Syskit::Composition.new_submodel(name: 'Cmp')
            cmp_m.add srv_m, as: 'test'

            profile.define('test', cmp_m)
            actions.use_profile(profile)
            actions.class_eval do
                describe 'test'
                define_method(:test_def) do
                    super().use('test' => deployed_task_m)
                end
            end
            cmp = syskit_deploy(actions.new(plan).test_def)
            assert_kind_of task_m, cmp.test_child
        end
    end

    describe "#robot" do
        it "registers the new devices as actions" do
            dev_m = Syskit::Device.new_submodel
            driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for dev_m, as: 'test'

            actions = Roby::Actions::Interface.new_submodel
            actions.robot do
                device dev_m, as: 'test'
            end
            action_m = actions.find_action_by_name('test_dev')
            assert action_m
            assert_equal driver_m.test_srv, action_m.to_instance_requirements.model
        end
    end
end

