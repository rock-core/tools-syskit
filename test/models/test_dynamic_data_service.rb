# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe DynamicDataService do
            describe "#demoted" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    srv_m = Syskit::DataService.new_submodel
                    @dyn_m = @task_m.dynamic_service srv_m, as: "test" do
                    end
                end

                it "returns self if called from the base model" do
                    assert_same @dyn_m, @dyn_m.demoted
                end
                it "returns the parent's model if called from a promoted model" do
                    sub_m = @task_m.new_submodel
                    refute_equal @dyn_m, sub_m.find_dynamic_service("test")
                    assert_same @dyn_m, sub_m.find_dynamic_service("test").demoted
                end
                it "returns the initial model regardless of the number of levels" do
                    sub_m = @task_m.new_submodel
                    subsub_m = sub_m.new_submodel
                    refute_equal @dyn_m, subsub_m.find_dynamic_service("test")
                    assert_same @dyn_m, subsub_m.find_dynamic_service("test").demoted
                end
            end
        end
    end
end
