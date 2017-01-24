require 'syskit/test/self'

module SyskitProfileTest
end

describe Syskit::Actions::Profile do
    describe "#initialize" do
        it "does not register the profile as a submodel of Profiles by default" do
            new_profile = Syskit::Actions::Profile.new
            refute Syskit::Actions::Profile.each_submodel.to_a.include?(new_profile)
        end

        it "registers the profile if register: true" do
            new_profile = Syskit::Actions::Profile.new(register: true)
            assert Syskit::Actions::Profile.each_submodel.to_a.include?(new_profile)
        end

        it "sets the profile's name" do
            profile = Syskit::Actions::Profile.new("name")
            assert_equal "name", profile.name
        end
    end

    describe "global #profile method" do
        before do
            @context = Module.new
        end

        it "registers the newly created profile as a submodel of Profile" do
            new_profile = @context.profile("Test") {}
            assert Syskit::Actions::Profile.each_submodel.to_a.include?(new_profile)
        end

        it "registers the newly created profile as a constant on the context module" do
            new_profile = @context.profile("Test") {}
            assert_same @context::Test, new_profile
        end

        it "evaluates the block on an already registered constant with the same name" do
            test_profile = @context.profile("Test") {}
            flexmock(Syskit::Actions::Profile).should_receive(:new).never

            eval_context = nil
            @context.profile("Test") do
                eval_context = self
            end
            assert_same test_profile, eval_context
        end
    end

    describe "#use_profile" do
        attr_reader :definition_mock
        before do
            @definition_mock = flexmock(arguments: [], with_arguments: nil)
            definition_mock.should_receive(:push_selections).by_default
            definition_mock.should_receive(:composition_model?).by_default
            definition_mock.should_receive(:use).by_default
            definition_mock.should_receive(:doc).by_default
        end

        it "resets the profile to the new profile" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m
            dst = Syskit::Actions::Profile.new
            dst.use_profile src
            assert_same src, src.test_def.profile
            assert_same dst, dst.test_def.profile
        end

        it "imports the existing definitions" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m

            dst = Syskit::Actions::Profile.new
            flexmock(dst).should_receive(:register_definition).with('test', src.test_def, doc: nil).once.
                and_return(definition_mock)
            dst.use_profile src
        end

        it "allows to transform the definition names" do
            src = Syskit::Actions::Profile.new
            src.define 'test', Syskit::TaskContext.new_submodel

            dst = Syskit::Actions::Profile.new
            dst.use_profile src, transform_names: ->(name) { "modified_#{name}" }

            assert_equal 'modified_test', dst.modified_test_def.name
            assert_equal src.test_def, dst.modified_test_def
        end

        it "uses the existing definition's documentation as documentation for the imported definition" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            req = src.define 'test', task_m
            req.doc "test documentation"

            dst = Syskit::Actions::Profile.new
            flexmock(dst).should_receive(:register_definition).with('test', src.test_def, doc: "test documentation").once.
                and_return(definition_mock)
            dst.use_profile src
        end

        it "does not import definitions that are already existing on the receiver" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m

            dst = Syskit::Actions::Profile.new
            dst.define 'test', task_m
            flexmock(dst).should_receive(:define).never
            dst.use_profile src
        end

        it "pushes selections before defining on the receiver if the model is a composition" do
            cmp_m = Syskit::Composition.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', cmp_m

            define = flexmock(src.definitions['test'])
            define.should_receive(:dup).once.
                and_return(duped = definition_mock)
            duped.should_receive(:push_selections).once
            dst = Syskit::Actions::Profile.new
            flexmock(dst).should_receive(:register_definition).with('test', duped, doc: nil).once.
                and_return(duped)
            dst.use_profile src
        end

        it "resolves definitions using the use flags" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: 'srv' }
            profile = Syskit::Actions::Profile.new
            profile.use srv_m => task_m
            profile.define 'test', srv_m

            assert_equal task_m.srv_srv, profile.test_def.service
        end

        it "applies selections on the requirement's use flags" do
            parent_srv_m = Syskit::DataService.new_submodel(name: 'ParentSrv')
            srv_m  = Syskit::DataService.new_submodel(name: 'Srv') { provides parent_srv_m }
            task_m = Syskit::TaskContext.new_submodel(name: 'Task') { provides srv_m, as: 'srv' }
            cmp_m  = Syskit::Composition.new_submodel(name: 'Cmp') do
                add parent_srv_m, as: 'c'
            end
            profile = Syskit::Actions::Profile.new
            profile.use srv_m => task_m
            profile.define 'test', cmp_m.use(srv_m)

            req = profile.resolved_definition('test')
            task = req.instanciate(plan)
            assert_equal task_m, task.c_child.model
        end

        it "allows to apply selections to tags" do
            srv_m = Syskit::DataService.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: 'test'
            src = Syskit::Actions::Profile.new
            src.tag 'test', srv_m
            src.define 'test', src.test_tag

            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: 'test'
            dst = Syskit::Actions::Profile.new
            dst.use_profile src, 'test' => task_m
        end

        it "also promotes definitions that are used as arguments" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel do
                argument :requirement
            end
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: 'test'
            parent_profile = Syskit::Actions::Profile.new
            parent_profile.tag 'test', srv_m
            parent_profile.define 'argument_action',
                cmp_m.use(parent_profile.test_tag)
            parent_profile.define 'test',
                task_m.with_arguments(action: parent_profile.argument_action_def.to_action_model)

            srv_task_m = Syskit::TaskContext.new_submodel
            srv_task_m.provides srv_m, as: 'test'
            child_profile = Syskit::Actions::Profile.new
            child_profile.use_profile parent_profile, 'test' => srv_task_m
            task = child_profile.test_def.arguments[:action].requirements.instanciate(plan)
            assert_kind_of srv_task_m, task.test_child
        end
    end

    describe "#define" do
        it "adds a Definition object in which the arguments is merged" do
            req = Syskit::InstanceRequirements.new
            flexmock(Syskit::Actions::Profile::Definition).new_instances.should_receive(:merge).with(req).once
            profile = Syskit::Actions::Profile.new
            result = profile.define 'test', req
            assert_kind_of(Syskit::Actions::Profile::Definition, result)
        end
        it "properly sets the name and profile of the definition object" do
            req = Syskit::InstanceRequirements.new
            profile = Syskit::Actions::Profile.new
            result = profile.define 'test', req
            assert_equal 'test', result.name
            assert_same profile, result.profile
        end
    end

    describe "#use" do
        it "should allow to globally inject dependencies in all definitions" do
            srv_m = Syskit::DataService.new_submodel name: "Srv"
            task_m = Syskit::TaskContext.new_submodel name: "Task"
            task_m.provides srv_m, as: 'test'
            cmp = Syskit::Composition.new_submodel
            cmp.add srv_m, as: 'test'
            profile = Syskit::Actions::Profile.new
            profile.use srv_m => task_m
            profile.define 'test', cmp
            di = profile.resolved_definition('test').resolved_dependency_injection
            _, sel = di.selection_for(nil, srv_m)
            assert_equal task_m, sel.model, "expected #{task_m}, got #{sel.model}"
        end
    end

    describe "#method_missing" do
        attr_reader :profile, :dev_m, :driver_m
        before do
            @profile = Syskit::Actions::Profile.new
            @dev_m = Syskit::Device.new_submodel
            @driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for dev_m, as: 'driver'
        end
        it "gives access to tags" do
            srv_m = Syskit::DataService.new_submodel
            srv = profile.tag 'test', srv_m
            assert_same srv, profile.test_tag
        end
        it "raises NoMethodError for unknown tags" do
            assert_raises(NoMethodError) do
                profile.test_tag
            end
        end
        it "raises ArgumentError if arguments are given to a _tag method" do
            profile.tag 'test', Syskit::DataService.new_submodel
            assert_raises(ArgumentError) do
                profile.test_tag('bla')
            end
        end

        it "gives access to definitions" do
            profile.define 'test', Syskit::DataService.new_submodel
            flexmock(profile).should_receive(:definition).with('test').and_return(d = flexmock)
            assert_same d, profile.test_def
        end
        it "raises NoMethodError for unknown definitions" do
            assert_raises(NoMethodError) do
                profile.test_def
            end
        end
        it "raises ArgumentError if arguments are given to a _def method" do
            profile.define 'test', Syskit::DataService.new_submodel
            assert_raises(ArgumentError) do
                profile.test_def('bla')
            end
        end

        it "gives access to devices" do
            device = profile.robot.device dev_m, as: 'test'
            assert_same driver_m.driver_srv, profile.test_dev.base_model
            assert_same device, profile.test_dev.arguments['driver_dev']
        end
        it "raises NoMethodError for unknown devices" do
            assert_raises(NoMethodError) do
                profile.test_dev
            end
        end
        it "raises ArgumentError if arguments are given to a _dev method" do
            profile.robot.device dev_m, as: 'test'
            assert_raises(ArgumentError) do
                profile.test_dev('bla')
            end
        end
    end

    it "should be usable through droby" do
        SyskitProfileTest.profile 'Test' do
        end
        assert_droby_compatible(SyskitProfileTest::Test)
    end

    it "gets its cached dependency injection object invalidated when the robot is modified" do
        profile = Syskit::Actions::Profile.new
        flexmock(profile).should_receive(:invalidate_dependency_injection).at_least.once
        profile.robot.invalidate_dependency_injection
    end

    describe "#tag" do
        it "cannot be merged with another tag of the same type" do
            srv_m = Syskit::DataService.new_submodel
            profile = Syskit::Actions::Profile.new
            profile.tag 'test', srv_m
            profile.tag 'other', srv_m
            test_task  = profile.test_tag.instanciate(plan)
            other_task = profile.other_tag.instanciate(plan)
            refute test_task.can_merge?(other_task)
        end
        it "can be merged with another instance of itself" do
            srv_m = Syskit::DataService.new_submodel
            profile = Syskit::Actions::Profile.new
            profile.tag 'test', srv_m
            test_task_1  = profile.test_tag.instanciate(plan)
            test_task_2  = profile.test_tag.instanciate(plan)
            assert test_task_1.can_merge?(test_task_2)
        end
    end
end

