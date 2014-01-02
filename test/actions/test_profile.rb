require 'syskit/test/self'

module SyskitProfileTest
    profile 'Test' do
    end
end

describe Syskit::Actions::Profile do
    include Syskit::Test::Self

    describe "#use_profile" do
        attr_reader :definition_mock
        before do
            @definition_mock = flexmock
            definition_mock.should_receive(:push_selections).by_default
            definition_mock.should_receive(:composition_model?).by_default
            definition_mock.should_receive(:use).by_default
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

        it "imports the existing definitions using #define" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m

            dst = Syskit::Actions::Profile.new
            flexmock(dst).should_receive(:define).with('test', src.test_def).once
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
            flexmock(dst).should_receive(:define).with('test', duped).once
            dst.use_profile src
        end

        it "resolves definitions using the use flags" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, :as => 'srv' }
            profile = Syskit::Actions::Profile.new
            profile.use srv_m => task_m
            profile.define 'test', srv_m

            assert_equal task_m.srv_srv, profile.test_def.service
        end

        it "applies selections on the requirement's use flags" do
            parent_srv_m = Syskit::DataService.new_submodel(:name => 'ParentSrv')
            srv_m  = Syskit::DataService.new_submodel(:name => 'Srv') { provides parent_srv_m }
            task_m = Syskit::TaskContext.new_submodel(:name => 'Task') { provides srv_m, :as => 'srv' }
            cmp_m  = Syskit::Composition.new_submodel(:name => 'Cmp') do
                add parent_srv_m, :as => 'c'
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
            cmp_m.add srv_m, :as => 'test'
            src = Syskit::Actions::Profile.new
            src.tag 'test', srv_m
            src.define 'test', src.test_tag

            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, :as => 'test'
            dst = Syskit::Actions::Profile.new
            dst.use_profile src, 'test' => task_m
        end
    end

    describe "#define" do
        it "resolves the given argument by calling #to_instance_requirements" do
        end
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

    describe "#method_missing" do
        attr_reader :profile, :dev_m
        before do
            @profile = Syskit::Actions::Profile.new
            @dev_m = Syskit::Device.new_submodel
            driver_m = Syskit::TaskContext.new_submodel
            driver_m.driver_for dev_m, :as => 'driver'
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
            device = profile.robot.device dev_m, :as => 'test'
            assert_same device, profile.test_dev
        end
        it "raises NoMethodError for unknown devices" do
            assert_raises(NoMethodError) do
                profile.test_dev
            end
        end
        it "raises ArgumentError if arguments are given to a _dev method" do
            profile.robot.device dev_m, :as => 'test'
            assert_raises(ArgumentError) do
                profile.test_dev('bla')
            end
        end
    end

    it "should be usable through droby" do
        verify_is_droby_marshallable_object(SyskitProfileTest::Test)
    end
end

