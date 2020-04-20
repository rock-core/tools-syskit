# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe BoundDynamicDataService do
            describe "#same_service?" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    @srv_m  = srv_m = Syskit::DataService.new_submodel
                    @dyn_m  = @task_m.dynamic_service srv_m, as: "test" do
                        provides srv_m, as: "test"
                    end
                end

                it "returns true if it comes from the same dynamic service with the same options" do
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42
                    sub2_m = @task_m.specialize
                    sub2_m.require_dynamic_service "test", as: "test", option1: 42
                    assert sub1_m.test_srv.same_service?(sub2_m.test_srv)
                end
                it "returns true even if the specialization happened at different levels" do
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42

                    sub_m = @task_m.new_submodel
                    sub2_m = sub_m.specialize
                    sub2_m.require_dynamic_service "test", as: "test", option1: 42
                    assert sub1_m.test_srv.same_service?(sub2_m.test_srv)
                end
                it "returns false if it has different options" do
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42
                    sub2_m = @task_m.specialize
                    sub2_m.require_dynamic_service "test", as: "test", option1: 84
                    refute sub1_m.test_srv.same_service?(sub2_m.test_srv)
                end
                it "returns false if it comes from a different dynamic service" do
                    srv_m = @srv_m
                    @task_m.dynamic_service srv_m, as: "other" do
                        provides srv_m, as: "test"
                    end
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42
                    sub2_m = @task_m.specialize
                    sub2_m.require_dynamic_service "test", as: "test", option1: 84
                    refute sub1_m.test_srv.same_service?(sub2_m.test_srv)
                end
                it "returns false if given a non-dynamic service" do
                    srv_m = @srv_m
                    @task_m.provides srv_m, as: "other"
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42
                    sub2_m = @task_m.specialize
                    refute sub1_m.test_srv.same_service?(sub2_m.other_srv)
                end
                it "returns false if given a task model" do
                    sub1_m = @task_m.specialize
                    sub1_m.require_dynamic_service "test", as: "test", option1: 42
                    refute sub1_m.test_srv.same_service?(@task_m)
                end
            end
        end
    end
end
