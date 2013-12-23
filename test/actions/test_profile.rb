require 'syskit/test/self'

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

        it "copies the original definitions in the new profile" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m

            define = flexmock(src.definitions['test'])
            define.should_receive(:dup).
                and_return(duped = definition_mock)
            dst = Syskit::Actions::Profile.new
            dst.use_profile src
            assert_same duped, dst.definitions['test'] 
        end

        it "pushes selections on the copied definition" do
            task_m = Syskit::TaskContext.new_submodel
            src = Syskit::Actions::Profile.new
            src.define 'test', task_m

            define = flexmock(src.definitions['test'])
            define.should_receive(:dup).once.
                and_return(duped = definition_mock)
            duped.should_receive(:composition_model?).and_return(true)
            duped.should_receive(:push_selections).once
            dst = Syskit::Actions::Profile.new
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
    end
end

