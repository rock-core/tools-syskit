# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe Placeholder do
        before do
            @srv_out_m = Syskit::DataService.new_submodel { output_port "out", "/double" }
            @srv_in_m = Syskit::DataService.new_submodel { input_port "in", "/double" }
        end

        describe "handling of replacements" do
            before do
                @parent_task_m = Syskit::TaskContext.new_submodel do
                    input_port "in_parent_task", "/float"
                    output_port "out_parent_task", "/float"
                end
                @task_m = @parent_task_m.new_submodel do
                    input_port "in_task", "/double"
                    output_port "out_task", "/double"
                end
                @task_m.provides @srv_out_m, as: "out"
                @task_m.provides @srv_in_m, as: "in"

                @cmp_m = Syskit::Composition.new_submodel
                @cmp_m.add @task_m, as: "task"
                @cmp_m.add @srv_out_m, as: "out_test"
                @cmp_m.add @srv_in_m, as: "in_test"

                @cmp_m.task_child.out_task_port.connect_to @cmp_m.in_test_child.in_port
                @cmp_m.out_test_child.out_port.connect_to @cmp_m.task_child.in_task_port
                @cmp = @cmp_m.instanciate(plan)
            end

            describe "#replace_task" do
                it "port-maps when replacing a placeholder for only data services" do
                    plan.add(task = @task_m.new)
                    plan.replace_task(@cmp.out_test_child, task)
                    plan.replace_task(@cmp.in_test_child, task)

                    assert task.out_task_port.connected_to?(@cmp.task_child.in_task_port)
                    assert @cmp.task_child.out_task_port.connected_to?(task.in_task_port)
                end

                it "port-maps when replacing a placeholder that has a component base" do
                    cmp_m = @cmp_m.new_submodel
                    cmp_m.overload "out_test", @parent_task_m
                    cmp_m.overload "in_test", @parent_task_m
                    cmp_m.task_child.out_parent_task_port
                         .connect_to cmp_m.in_test_child.in_parent_task_port
                    cmp_m.out_test_child.out_parent_task_port
                         .connect_to cmp_m.task_child.in_parent_task_port

                    cmp = cmp_m.instanciate(plan)

                    plan.add(task = @task_m.new)
                    plan.replace_task(cmp.out_test_child, task)
                    plan.replace_task(cmp.in_test_child, task)

                    assert task.out_parent_task_port.connected_to?(
                        cmp.task_child.in_parent_task_port
                    )
                    assert cmp.task_child.out_parent_task_port.connected_to?(
                        task.in_parent_task_port
                    )
                    assert task.out_task_port.connected_to?(cmp.task_child.in_task_port)
                    assert cmp.task_child.out_task_port.connected_to?(task.in_task_port)
                end
            end

            describe "#replace" do
                it "port-maps when replacing a placeholder for only data services" do
                    plan.add(task = @task_m.new)
                    plan.replace(@cmp.out_test_child, task)
                    plan.replace(@cmp.in_test_child, task)

                    assert task.out_task_port.connected_to?(@cmp.task_child.in_task_port)
                    assert @cmp.task_child.out_task_port.connected_to?(task.in_task_port)
                end

                it "port-maps when replacing a placeholder that has a component base" do
                    cmp_m = @cmp_m.new_submodel
                    cmp_m.overload "out_test", @parent_task_m
                    cmp_m.overload "in_test", @parent_task_m
                    cmp_m.task_child.out_parent_task_port
                         .connect_to cmp_m.in_test_child.in_parent_task_port
                    cmp_m.out_test_child.out_parent_task_port
                         .connect_to cmp_m.task_child.in_parent_task_port

                    cmp = cmp_m.instanciate(plan)

                    plan.add(task = @task_m.new)
                    plan.replace(cmp.out_test_child, task)
                    plan.replace(cmp.in_test_child, task)

                    assert task.out_parent_task_port.connected_to?(
                        cmp.task_child.in_parent_task_port
                    )
                    assert cmp.task_child.out_parent_task_port.connected_to?(
                        task.in_parent_task_port
                    )
                    assert task.out_task_port.connected_to?(cmp.task_child.in_task_port)
                    assert cmp.task_child.out_task_port.connected_to?(task.in_task_port)
                end
            end
        end
    end
end
