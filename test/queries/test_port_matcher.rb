# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Queries
        describe PortMatcher do
            # NOTE: most of the PortMatcher functionality is tested
            # through the ComponentMatcher and DataServiceMatcher tests

            before do
                @task_m = TaskContext.new_submodel do
                    input_port "in_d", "/double"
                    output_port "out_d", "/double"
                    output_port "out_f", "/float"
                end
            end

            it "matches all ports of the component matcher by default" do
                plan.add(task = @task_m.new)
                assert_matcher_finds(
                    [task.in_d_port, task.out_d_port, task.out_f_port, task.state_port],
                    PortMatcher.new(@task_m)
                )
            end

            it "optionally allows to filter with an exact name" do
                plan.add(task = @task_m.new)
                assert_matcher_finds [task.out_d_port],
                                     PortMatcher.new(@task_m).with_name("out_d")
            end

            it "optionally allows to filter with a name pattern" do
                plan.add(task = @task_m.new)
                assert_matcher_finds [task.out_d_port, task.out_f_port],
                                     PortMatcher.new(@task_m).with_name(/^out/)
            end

            it "optionally allows to filter with a type" do
                plan.add(task = @task_m.new)
                assert_matcher_finds [task.out_f_port],
                                     PortMatcher.new(@task_m)
                                                .with_type(@task_m.out_f_port.type)
            end

            it "combines name and type matching" do
                plan.add(task = @task_m.new)
                assert_finds_nothing PortMatcher.new(@task_m)
                                                .with_name("out_d")
                                                .with_type(@task_m.out_f_port.type)
                assert_matcher_finds [task.out_f_port],
                                     PortMatcher.new(@task_m)
                                                .with_name(/^out/)
                                                .with_type(@task_m.out_f_port.type)
            end

            describe "#try_resolve_type" do
                it "returns the type filter if set" do
                    component_matcher = @task_m.match
                    matcher = PortMatcher.new(component_matcher)
                                         .with_type(@task_m.out_d_port.type)
                    assert_equal "/double", matcher.try_resolve_type.name
                end

                it "returns nil if the name filter is a patter" do
                    component_matcher = @task_m.match
                    matcher = PortMatcher.new(component_matcher).with_name(/out_d/)
                    assert_nil matcher.try_resolve_type
                end

                it "returns the type of the underlying component's port "\
                   "if an explicit name is given" do
                    component_matcher = @task_m.match
                    matcher = PortMatcher.new(component_matcher).with_name("out_d")
                    assert_equal "/double", matcher.try_resolve_type.name
                end

                it "returns nil if the underlying component matcher cannot "\
                   "resolve the port by name" do
                    component_matcher = @task_m.match
                    flexmock(component_matcher)
                        .should_receive(:find_port_by_name).with("bla")
                        .and_return(nil)
                    matcher = PortMatcher.new(component_matcher).with_name("bla")
                    assert_nil matcher.try_resolve_type
                end

                it "returns nil if the name is ambiguous for the component" do
                    component_matcher = @task_m.match
                    flexmock(component_matcher)
                        .should_receive(:find_port_by_name).with("bla")
                        .and_raise(Ambiguous)
                    matcher = PortMatcher.new(component_matcher).with_name("bla")
                    assert_nil matcher.try_resolve_type
                end
            end

            describe "#try_resolve_direction" do
                it "returns nil if the name is not set" do
                    matcher = PortMatcher.new(@task_m.match)
                    assert_nil matcher.try_resolve_direction
                end

                it "returns nil if the name filter is a pattern" do
                    matcher = PortMatcher.new(@task_m.match).with_name(/out_d/)
                    assert_nil matcher.try_resolve_direction
                end

                it "returns :output if the underlying component's port "\
                   "is an output and an explicit name is given" do
                    matcher = PortMatcher.new(@task_m.match).with_name("out_d")
                    assert_equal :output, matcher.try_resolve_direction
                end

                it "returns :input if the underlying component's port "\
                   "is an input and an explicit name is given" do
                    matcher = PortMatcher.new(@task_m.match).with_name("in_d")
                    assert_equal :input, matcher.try_resolve_direction
                end

                it "returns nil if the underlying component matcher cannot "\
                   "resolve the port by name" do
                    component_matcher = @task_m.match
                    flexmock(component_matcher)
                        .should_receive(:find_port_by_name).with("bla")
                        .and_return(nil)
                    matcher = PortMatcher.new(component_matcher).with_name("bla")
                    assert_nil matcher.try_resolve_direction
                end

                it "returns nil if the name is ambiguous for the component" do
                    component_matcher = @task_m.match
                    flexmock(component_matcher)
                        .should_receive(:find_port_by_name).with("bla")
                        .and_raise(Ambiguous)
                    matcher = PortMatcher.new(component_matcher).with_name("bla")
                    assert_nil matcher.try_resolve_direction
                end
            end

            def assert_finds_nothing(matcher)
                assert_matcher_finds [], matcher
            end

            def assert_matcher_finds(expected, matcher)
                result = matcher.to_set(plan)
                assert_equal expected.to_set, result
            end
        end
    end
end
