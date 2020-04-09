# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe TaskConfigurationManager do
        before do
            Roby.app.import_types_from "base"
            rbs_t = @rbs_t = Roby.app.default_loader
                                 .resolve_type("/base/samples/RigidBodyState")
            @task_m = Syskit::TaskContext.new_submodel do
                property "foo", rbs_t
            end
        end

        describe "#apply" do
            it "applies converted fields before applying the configuration" do
                task = syskit_stub_and_deploy(@task_m)
                task.properties.foo = Roby.app.default_loader
                                          .resolve_type("/base/samples/RigidBodyState_m").new
                task.properties.foo.time = Time.at(10)
                task.properties.foo.position = Eigen::Vector3.new(1, 2, 3)
                syskit_stub_conf @task_m, "default", data: {
                    foo: { time: { microseconds: 20_000_000 } }
                }
                syskit_configure(task)
                Orocos.allow_blocking_calls do
                    assert_equal Time.at(20), task.orocos_task.foo.time
                    assert_equal Eigen::Vector3.new(1, 2, 3), task.orocos_task.foo.position
                end
            end
        end
    end
end
