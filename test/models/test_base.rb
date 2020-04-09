# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::Models do
    describe "is_model?" do
        it "should return false for nil" do
            assert !Syskit::Models.is_model?(nil)
        end
        it "should return false for any object" do
            assert !Syskit::Models.is_model?(flexmock)
        end

        it "should return false for strings" do
            assert !Syskit::Models.is_model?("10")
        end

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

        it "should return true for bound data services" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"

            assert Syskit::Models.is_model?(task_m.test_srv)
        end
    end
end
