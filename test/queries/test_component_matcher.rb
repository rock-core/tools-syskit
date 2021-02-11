# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Queries
        describe ComponentMatcher do
            before do
                @task_m = Syskit::TaskContext.new_submodel
            end

            it "resolves components" do
                plan.add(task = @task_m.new)
                assert_matcher_finds [task], @task_m.match
            end

            describe "the _srv accessor" do
                before do
                    @srv_m = Syskit::DataService.new_submodel
                    @task_m.provides @srv_m, as: "test"
                end

                it "resolves data services through the matcher returned "\
                "by the _srv accessor" do
                    plan.add(task = @task_m.new)
                    assert_matcher_finds [task.test_srv], @task_m.match.test_srv
                end

                it "raises if _srv is called for an unexisting service" do
                    e = assert_raises(NoMethodError) { @task_m.match.does_not_exist_srv }
                    assert_equal :does_not_exist_srv, e.name
                end

                it "works on composite models" do
                    other_srv_m = Syskit::DataService.new_submodel
                    matcher = ComponentMatcher.new.with_model([@task_m, other_srv_m])
                    task_m = @task_m.new_submodel
                    task_m.provides other_srv_m, as: "other"
                    plan.add(task = task_m.new)
                    assert_matcher_finds [task.test_srv], matcher.test_srv
                end
            end

            describe "the _port accessor" do
                before do
                    @task_m = Syskit::TaskContext.new_submodel do
                        output_port "out", "/double"
                    end
                    plan.add(@task = @task_m.new)
                end

                it "resolves task context ports through the matcher returned "\
                   "by the _port accessor" do
                    assert_matcher_finds [@task.out_port], @task_m.match.out_port
                end

                it "raises if the port does not exist by the _port accessor" do
                    e = assert_raises(NoMethodError) { @task_m.match.does_not_exist_port }
                    assert_equal :does_not_exist_port, e.name
                end

                it "raises if more than one port of the given name can be found" do
                    other_srv_m = Syskit::DataService.new_submodel do
                        output_port "out", "/double"
                    end
                    matcher = ComponentMatcher.new.with_model([@task_m, other_srv_m])
                    e = assert_raises(Ambiguous) { matcher.out_port }
                    assert_equal(
                        "more than one port named 'out' exist on composite model "\
                        "#{@task_m}, #{other_srv_m}. Select a data service explicitly "\
                        "to disambiguate", e.message
                    )
                end

                it "resolves the port type in try_resolve_type" do
                    assert_equal "/double", @task_m.match.out_port.try_resolve_type.name
                end
            end

            def assert_matcher_finds(expected, matcher)
                result = matcher.to_set(plan)
                assert_equal expected.to_set, result
            end
        end
    end
end
