# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    describe InvalidAutoConnection do
        describe "#pretty_print" do
            it "should not raise" do
                source = flexmock(each_output_port: [], each_input_port: [])
                sink   = flexmock(each_output_port: [], each_input_port: [])
                PP.pp(Syskit::InvalidAutoConnection.new(source, sink), "".dup)
            end
        end
    end

    describe ConflictingDeviceAllocation do
        it "displays the two driver tasks if they are the ones not mergeable" do
            device_m = Device.new_submodel(name: "D")
            driver_m = TaskContext.new_submodel(name: "T")
            driver_m.driver_for device_m, as: "test"
            robot = Robot::RobotDefinition.new
            robot.device device_m, as: "test"

            plan.add(task1 = driver_m.new(arg: 1, test_dev: robot.test_dev))
            plan.add(task2 = driver_m.new(arg: 2, test_dev: robot.test_dev))
            e = assert_raises(ConflictingDeviceAllocation) do
                NetworkGeneration::SystemNetworkGenerator
                    .new(plan).validate_generated_network
            end

            assert_equal Set[task1, task2], e.tasks.to_set
            formatted = PP.pp(e, +"")

            expected = <<~PP.chomp
                device 'test' of type D is assigned to two tasks that cannot be merged
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  T<id:ID>
                    no owners
                    arguments:
                      arg: 2,
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                Chain 2:
                  T<id:ID>
                    no owners
                    arguments:
                      arg: 1,
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end

        it "displays merge chains to explain why devices are duplicated" do
            device_m = Device.new_submodel(name: "D")
            driver_m = TaskContext.new_submodel(name: "Driver") do
                input_port "in", "/double"
            end
            driver_m.driver_for device_m, as: "test"
            task_m = TaskContext.new_submodel(name: "Task") do
                argument :arg
                output_port "out", "/double"
            end

            robot = Robot::RobotDefinition.new
            robot.device device_m, as: "test"

            plan.add(driver1 = driver_m.new(test_dev: robot.test_dev))
            plan.add(driver2 = driver_m.new(test_dev: robot.test_dev))
            plan.add(task1 = task_m.new(arg: 1))
            plan.add(task2 = task_m.new(arg: 2))
            task1.out_port.connect_to driver1.in_port
            task2.out_port.connect_to driver2.in_port
            e = assert_raises(ConflictingDeviceAllocation) do
                NetworkGeneration::SystemNetworkGenerator
                    .new(plan).validate_generated_network
            end

            assert_equal Set[driver1, driver2], e.tasks.to_set
            formatted = PP.pp(e, +"")

            expected = <<~PP.chomp
                device 'test' of type D is assigned to two tasks that cannot be merged
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  Driver<id:ID>
                    no owners
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  Task<id:ID>
                    no owners
                    arguments:
                      arg: 1,
                      conf: default(["default"]),
                      read_only: default(false)
                Chain 2:
                  Driver<id:ID>
                    no owners
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  Task<id:ID>
                    no owners
                    arguments:
                      arg: 2,
                      conf: default(["default"]),
                      read_only: default(false)
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end
    end
end
