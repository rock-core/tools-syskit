# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Test
        describe StubNetwork do
            before do
                @task_m = Syskit::TaskContext.new_submodel(name: "Task")
                @srv_m = Syskit::DataService.new_submodel(name: "Srv")
                @cmp_m = Syskit::Composition.new_submodel(name: "Cmp")
                @cmp_m.add @srv_m, as: "srv"
                @stubs = StubNetwork.new(self)
            end

            it "stubs an abstract task model" do
                @task_m.abstract
                plan.add(task = @task_m.instanciate(plan))
                task = @stubs.apply([task]).first

                refute task.abstract?

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start task
                end
            end

            it "stubs a composition" do
                cmp = @stubs.apply([@cmp_m.instanciate(plan)]).first
                assert_kind_of @cmp_m, cmp
                assert_kind_of @srv_m, cmp.srv_child

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.srv_child
                end
            end

            it "stubs data services" do
                srv_m = Syskit::DataService.new_submodel(name: "Srv") do
                    input_port "in", "/double"
                    output_port "out", "/double"
                end
                cmp_m = Syskit::Composition.new_submodel do
                    add srv_m, as: "test"
                end

                cmp = @stubs.apply([cmp_m.instanciate(plan)]).first

                refute cmp.test_child.abstract?
                assert cmp.test_child.find_data_service_from_type(srv_m)

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.test_child
                end
            end

            it "lets toplevel tasks be tracked using plan services" do
                task = @cmp_m.instanciate(plan)
                service = task.as_service
                final = @stubs.apply([task]).first

                assert_same final, service.to_task
            end

            it "lets non-toplevel tasks be tracked using plan services" do
                task = @cmp_m.instanciate(plan)
                task_child = task.srv_child
                service = task_child.as_service
                final = @stubs.apply([task]).first

                refute_same task_child, task.srv_child
                assert_same final.srv_child, service.to_task
            end

            it "creates a stub device drivers when given a device" do
                dev_m = Syskit::Device.new_submodel(name: "Dev")
                dev_m.provides @srv_m

                cmp = @stubs.apply(
                    [@cmp_m.use("srv" => dev_m).instanciate(plan)]
                ).first
                assert_kind_of @cmp_m, cmp
                assert_kind_of dev_m, cmp.srv_child
                assert_equal dev_m, cmp.srv_child.dev0_dev.model

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.srv_child
                end
            end

            it "creates a stub device model for driver tasks" do
                dev_m = Syskit::Device.new_submodel(name: "Dev")
                dev_m.provides @srv_m
                task_m = Syskit::TaskContext.new_submodel(name: "DevDriver")
                task_m.driver_for dev_m, as: "dev"

                cmp = @stubs.apply(
                    [@cmp_m.use("srv" => task_m).instanciate(plan)]
                ).first
                assert_equal dev_m, cmp.srv_child.dev_dev.model

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.srv_child
                end
            end

            it "stubs tags" do
                profile = Syskit::Actions::Profile.new "P"
                profile.tag "test", @srv_m

                cmp = @stubs.apply(
                    [@cmp_m.use("srv" => profile.test_tag).instanciate(plan)]
                ).first
                assert_kind_of @srv_m, cmp.srv_child

                # Make sure that stubbing created a network we can start
                expect_execution.scheduler(true).to do
                    start cmp
                    start cmp.srv_child
                end
            end
        end
    end
end
