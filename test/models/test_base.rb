require 'syskit'
require 'syskit/test'

describe Syskit::Models do
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
