# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Coordination
        describe "Action state machines" do
            before do
                @cmp_m = Syskit::Composition.new_submodel
                @interface_m = Roby::Actions::Interface.new_submodel
            end

            it "uses instance requirements directly" do
                cmp_m = @cmp_m
                @interface_m.describe("foo")
                @interface_m.action_state_machine "foo" do
                    start state(cmp_m)
                end
                plan.add(root = @interface_m.new(plan).foo)
                state_task, = expect_execution.scheduler(true).to do
                    achieve { root.each_child.first }
                end
                assert_kind_of @cmp_m, state_task
            end

            it "forwards a state machine argument to an instance requirements" do
                cmp_m = @cmp_m
                @cmp_m.argument :bar
                @interface_m.describe("foo")
                            .required_arg(:bar, "some argument")
                @interface_m.action_state_machine "foo" do
                    start state(cmp_m.with_arguments(bar: bar))
                end

                plan.add(root = @interface_m.new(plan).foo(bar: 10))
                state_task, = expect_execution.scheduler(true).to do
                    achieve { root.each_child.first }
                end
                assert_equal 10, state_task.planning_task.requirements.arguments[:bar]
            end
        end
    end
end
