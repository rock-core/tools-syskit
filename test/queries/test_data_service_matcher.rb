# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Queries
        describe DataServiceMatcher do
            before do
                @task_m = Syskit::TaskContext.new_submodel do
                    output_port "out", "/double"
                end
                @srv_m = Syskit::DataService.new_submodel do
                    output_port "srv_out", "/double"
                end
                @task_m.provides @srv_m, as: "test"
            end

            it "can be created from a component matcher" do
                plan.add(task = @task_m.new)
                matcher = @task_m.match.test_srv
                assert_equal @srv_m, matcher.data_service_model
                assert_matcher_finds [task.test_srv], matcher
            end

            describe "from a bound data service model" do
                it "can be created from a bound data service model" do
                    plan.add(task = @task_m.new)
                    matcher = @task_m.test_srv.match
                    assert_equal @srv_m, matcher.data_service_model
                    assert_matcher_finds [task.test_srv], matcher
                end

                it "gives access to mapped ports" do
                    plan.add(task = @task_m.new)
                    port_matcher = @task_m.test_srv.match.srv_out_port
                    assert_matcher_finds [task.test_srv.srv_out_port], port_matcher
                end

                it "accepts task matcher predicates" do
                    matcher = @task_m.test_srv.match.abstract
                    plan.add(task = @task_m.new)
                    assert_matcher_finds [], matcher
                    task.abstract = true
                    assert_matcher_finds [task.test_srv], matcher
                end
            end

            describe "from a data service model" do
                it "can be created from a data service model" do
                    plan.add(task = @task_m.new)
                    matcher = @srv_m.match
                    assert_matcher_finds [task.test_srv], matcher
                end

                it "gives access to mapped ports" do
                    plan.add(task = @task_m.new)
                    port_matcher = @srv_m.match.srv_out_port
                    assert_matcher_finds [task.test_srv.srv_out_port], port_matcher
                end

                it "accepts task matcher predicates when created "\
                   "on a data service model" do
                    matcher = @srv_m.match.abstract
                    plan.add(task = @task_m.new)
                    assert_matcher_finds [], matcher
                    task.abstract = true
                    assert_matcher_finds [task.test_srv], matcher
                end
            end

            describe "#as" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        output_port "out", "/double"
                    end
                    @base_srv_m = Syskit::DataService.new_submodel do
                        output_port "base_out", "/double"
                    end
                    @derived_srv_m = Syskit::DataService.new_submodel do
                        output_port "derived_out", "/double"
                    end
                    @derived_srv_m.provides @base_srv_m, "base_out" => "derived_out"
                    @task_m.provides @derived_srv_m, as: "test"
                end

                it "resolves the test service mapped to the base model" do
                    plan.add(task = @task_m.new)
                    assert_matcher_finds [task.test_srv.as(@base_srv_m)],
                                         @task_m.test_srv.match.as(@base_srv_m)
                end

                it "gives access to mapped ports" do
                    plan.add(task = @task_m.new)
                    port_matcher = @task_m.test_srv.match.as(@base_srv_m).base_out_port
                    matched_ports = port_matcher.to_a(plan)
                    assert_equal 1, matched_ports.size
                    p = matched_ports.shift
                    assert_equal task.test_srv.as(@base_srv_m), p.component
                    assert_equal task.out_port, p.to_component_port
                end

                it "raises if given an unrelated service model" do
                    srv_m = Syskit::DataService.new_submodel
                    e = assert_raises(ArgumentError) do
                        @task_m.test_srv.match.as(srv_m)
                    end
                    assert_equal "cannot refine match from "\
                                 "#{@derived_srv_m} to #{srv_m}", e.message
                end

                it "raises if given a derived service model" do
                    matcher = @task_m.test_srv.match.as(@base_srv_m)
                    e = assert_raises(ArgumentError) do
                        matcher.as(@derived_srv_m)
                    end
                    assert_equal "cannot refine match from "\
                                 "#{@base_srv_m} to #{@derived_srv_m}", e.message
                end
            end

            def assert_matcher_finds(expected, matcher)
                result = matcher.to_set(plan)
                assert_equal expected.to_set, result
            end
        end
    end
end
