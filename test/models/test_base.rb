require 'syskit/test'

describe Syskit::Models do
    include Syskit::SelfTest

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
