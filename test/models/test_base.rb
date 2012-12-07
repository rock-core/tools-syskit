require 'syskit'
require 'syskit/test'

describe Syskit::Models do
    include Syskit::SelfTest

    def model_stub(parent_model = nil)
        result = Class.new { extend Syskit::Models::Base }
        flexmock(result).should_receive(:supermodel).and_return(parent_model).by_default
        if parent_model
            parent_model.register_submodel(result)
        end
        result
    end

    describe "is_model?" do
        it "should return true for data services" do
            assert Syskit::Models.is_model?(Syskit::DataService)
            assert Syskit::Models.is_model?(Syskit::DataService.new_submodel)
        end

        it "should return true for components" do
            assert Syskit::Models.is_model?(Syskit::Component)
            assert Syskit::Models.is_model?(Syskit::Component.new_submodel)
        end

        it "should return true for compositions" do
            assert Syskit::Models.is_model?(Syskit::Composition), Syskit::Composition.ancestors
            assert Syskit::Models.is_model?(Syskit::Composition.new_submodel)
        end

        it "should return true for task contexts" do
            assert Syskit::Models.is_model?(Syskit::TaskContext)
            assert Syskit::Models.is_model?(Syskit::TaskContext.new_submodel)
        end
    end

    describe "#register_submodel" do
        attr_reader :base_model
        before do
            @base_model = model_stub
        end

        it "registers the model on the receiver" do
            sub_model = flexmock
            base_model.register_submodel(sub_model)
            assert(base_model.each_submodel.find { |m| m == sub_model })
        end
        it "registers the model on the receiver's parent model" do
            parent_model = flexmock
            sub_model = flexmock
            flexmock(base_model).should_receive(:supermodel).and_return(parent_model)
            flexmock(parent_model).should_receive(:register_submodel).with(sub_model).once
            base_model.register_submodel(sub_model)
        end
    end

    describe "#deregister_submodel" do
        attr_reader :base_model, :sub_model
        before do
            @base_model = model_stub
            @sub_model = model_stub(base_model)
        end

        it "deregisters the models on the receiver" do
            flexmock(base_model).should_receive(:supermodel).and_return(nil).once
            base_model.deregister_submodels([sub_model])
            assert(base_model.each_submodel.empty?)
        end
        it "deregisters the models on the receiver's parent model" do
            parent_model = flexmock
            flexmock(base_model).should_receive(:supermodel).and_return(parent_model)
            flexmock(parent_model).should_receive(:deregister_submodels).with([sub_model]).once
            base_model.deregister_submodels([sub_model])
        end
        it "does not call the parent model's deregister method if there are not models to deregister" do
            parent_model = flexmock
            flexmock(base_model).should_receive(:supermodel).and_return(parent_model)
            flexmock(parent_model).should_receive(:deregister_submodels).with([sub_model]).never
            base_model.deregister_submodels([flexmock])
        end
        it "returns true if a model got deregistered" do
            flexmock(base_model).should_receive(:supermodel).and_return(nil).once
            assert base_model.deregister_submodels([sub_model])
        end
        it "returns false if no models got deregistered" do
            assert !base_model.deregister_submodels([flexmock])
        end
    end

    describe "#clear_models" do
        attr_reader :base_model, :sub_model
        before do
            @base_model = model_stub
            @sub_model = model_stub(base_model)
        end
        it "deregisters the non-permanent models" do
            flexmock(base_model).should_receive(:deregister_submodels).with([sub_model]).once
            base_model.clear_submodels
        end
        it "does not call #clear_submodels in submodels if there are no models to clear" do
            flexmock(sub_model).should_receive(:permanent_model?).and_return(true).once
            flexmock(sub_model).should_receive(:clear_submodels).never
            base_model.clear_submodels
        end
        it "calls #clear_submodels on non-permanent submodels" do
            flexmock(sub_model).should_receive(:permanent_model?).and_return(false).once
            flexmock(sub_model).should_receive(:clear_submodels).once
            base_model.clear_submodels
        end
        it "calls #clear_submodels on permanent submodels" do
            flexmock(sub_model).should_receive(:permanent_model?).and_return(true).once
            flexmock(sub_model).should_receive(:clear_submodels).once
            # Create another submodel so that there is something to clear
            model_stub(base_model)
            base_model.clear_submodels
        end
        it "does not deregister the permanent models" do
            flexmock(sub_model).should_receive(:permanent_model?).and_return(true).once
            flexmock(base_model).should_receive(:deregister_submodels).with([]).once
            base_model.clear_submodels
        end
        it "should deregister before it clears" do
            flexmock(sub_model).should_receive(:permanent_model?).and_return(false).once
            flexmock(base_model).should_receive(:deregister_submodels).once.ordered.pass_thru
            flexmock(sub_model).should_receive(:clear_submodels).once.ordered
            base_model.clear_submodels
        end
    end
end

# class TC_Models_Base
#     include Syskit::SelfTest
# 
#     def test_merge_model_lists_with_empty_initial_set
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_with_empty_target_set
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_with_only_services_and_no_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_with_only_services_and_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_with_only_components_and_no_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_with_only_components_and_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_mixed_and_no_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_mixed_and_service_redundancies
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_mixed_and_component_providing_services
#         raise NotImplementedError
#     end
# 
#     def test_merge_model_lists_raises_if_incompatible_component_models_are_found
#         raise NotImplementedError
#     end
# end
