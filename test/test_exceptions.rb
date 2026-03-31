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
                  T<id:ID> pending
                    arguments:
                      arg: 2,
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                Chain 2:
                  T<id:ID> pending
                    arguments:
                      arg: 1,
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end

        it "displays definitions that depend on the conflicting tasks" do
            device_m = Device.new_submodel(name: "D")
            driver_m = TaskContext.new_submodel(name: "T")
            driver_m.argument :arg
            driver_m.driver_for device_m, as: "test"
            robot = Robot::RobotDefinition.new
            robot.device device_m, as: "test"

            cmp_m = Composition.new_submodel
            cmp_m.add device_m, as: "test"
            profile = Actions::Profile.new("Test")
            profile.define("test1", cmp_m)
                   .use("test" => robot.test_dev.with_arguments(arg: 1))
            profile.define("test2", cmp_m)
                   .use("test" => robot.test_dev.with_arguments(arg: 2))

            self.syskit_run_planner_validate_network = true
            e = if Syskit.conf.capture_errors_during_network_resolution?
                    expect_execution do
                        run_planners([profile.test1_def, profile.test2_def])
                    end.to { have_error_matching Roby::PlanningFailedError.match }
                        .exception.original_exceptions.first
                else
                    assert_raises(ConflictingDeviceAllocation) do
                        run_planners([profile.test1_def, profile.test2_def])
                    end
                end

            formatted = PP.pp(e, +"")
            expected = <<~PP.chomp
                device 'test' of type D is assigned to two tasks that cannot be merged
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  T<id:ID> pending
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      arg: 2,
                      conf: ["default"],
                      read_only: false
                Chain 2:
                  T<id:ID> pending
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      arg: 1,
                      conf: ["default"],
                      read_only: false
                T<id:ID>(arg: 2, conf: ["default"], read_only: false, \
                test_dev: device(D, as: test)) is needed by the following definitions:
                  Test.test2_def
                T<id:ID>(arg: 1, conf: ["default"], read_only: false, \
                test_dev: device(D, as: test)) is needed by the following definitions:
                  Test.test1_def
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
                  Driver<id:ID> pending
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  Task<id:ID> pending
                    arguments:
                      arg: 1,
                      conf: default(["default"]),
                      read_only: default(false)
                Chain 2:
                  Driver<id:ID> pending
                    arguments:
                      test_dev: MasterDeviceInstance(test[D]_dev),
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  Task<id:ID> pending
                    arguments:
                      arg: 2,
                      conf: default(["default"]),
                      read_only: default(false)
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end

        it "properly sets up the merge solver to compute the failed chains" do
            # Originally, the merge solver was NOT setup with early_deploy set,
            # which led the exception to fail on pretty printing in case the merge
            # was OK with early_deploy: false
            #
            # This essentially happens if the conflict appears because of an
            # input that is not deployed
            input_task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            device_m = Syskit::Device.new_submodel(name: "D")
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                driver_for device_m, as: "driver"
            end
            syskit_stub_configured_deployment(task_m, "task")

            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "task"
            cmp_m.add input_task_m, as: "input"
            cmp_m.input_child.connect_to cmp_m.task_child

            dev = syskit_stub_device(device_m, as: "stubD")
            cmp_m.use("task" => dev.with_arguments(orocos_name: "task"))
                 .instanciate(plan)
            cmp_m.use("task" => dev.with_arguments(orocos_name: "task"))
                 .instanciate(plan)

            merge_solver = NetworkGeneration::MergeSolver.new(
                plan, merge_task_contexts_with_same_agent: true
            )
            error_handler = NetworkGeneration::ResolutionErrorHandler.new(
                plan, merge_solver
            )
            NetworkGeneration::SystemNetworkGenerator
                .new(plan, error_handler: error_handler, early_deploy: true)
                .validate_generated_network

            failure = error_handler.resolution_failures.find do
                _1.original_exception.kind_of?(ConflictingDeviceAllocation)
            end
            e = failure.original_exception
            assert e
            formatted = PP.pp(e, +"")

            expected = <<~PP.chomp
                device 'stubD' of type D is assigned to two tasks that cannot be merged
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  <id:ID> pending
                    arguments:
                      driver_dev: MasterDeviceInstance(stubD[D]_dev),
                      orocos_name: "task",
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  <id:ID> pending
                    arguments:
                      conf: default(["default"]),
                      read_only: default(false)
                Chain 2:
                  <id:ID> pending
                    arguments:
                      driver_dev: MasterDeviceInstance(stubD[D]_dev),
                      orocos_name: "task",
                      conf: default(["default"]),
                      read_only: default(false)
                  sink in_port connected via policy {} to source out_port of
                  <id:ID> pending
                    arguments:
                      conf: default(["default"]),
                      read_only: default(false)
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end
    end

    describe ConflictingDeploymentAllocation do
        # This exception appears only in early_deploy context

        attr_reader :net_gen, :profile

        before do
            Roby.app.using_task_library "orogen_syskit_tests"

            @task_m = Syskit::TaskContext.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end
            syskit_stub_configured_deployment(@task_m, "task")

            @cmp_m = Syskit::Composition.new_submodel
            @cmp_m.add(@task_m, as: "task")

            @net_gen_plan = Roby::Plan.new
            @net_gen = NetworkGeneration::SystemNetworkGenerator.new(
                @net_gen_plan,
                default_deployment_group: default_deployment_group, early_deploy: true
            )
            @net_gen.merge_solver.merge_task_contexts_with_same_agent = true

            @old_early_deply = Syskit.conf.early_deploy?
            Syskit.conf.early_deploy = true
        end

        after do
            Syskit.conf.early_deploy = @old_early_deply
        end

        it "displays deployment allocation conflicts, shows that the tasks themselves " \
           "are in conflict and list non deployed toplevel definitions" do
            profile = Actions::Profile.new("Test")
            profile.define("test1", @cmp_m)
                   .use("task" => @task_m.with_arguments(arg: 1))
            profile.define("test2", @cmp_m)
                   .use("task" => @task_m.with_arguments(arg: 2))

            e = assert_raises(ConflictingDeploymentAllocation) do
                net_gen.compute_system_network(
                    [profile.test1_def, profile.test2_def]
                )
            end
            formatted = PP.pp(e, +"")

            expected = <<~PP.chomp
                deployed task 'task' from deployment \
                'task' defined in '' on 'stubs' is assigned to 2 tasks. Below is \
                the list of the dependent non-deployed actions. Right after the \
                list is a detailed explanation of why the first two tasks are not merged:
                <id:ID>(arg: 1, conf: ["default"], orocos_name: task, read_only: false) \
                is needed by the following definitions:
                  Test.test1_def
                <id:ID>(arg: 2, conf: ["default"], orocos_name: task, read_only: false) \
                is needed by the following definitions:
                  Test.test2_def
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  <id:ID> pending
                    arguments:
                      orocos_name: "task",
                      read_only: false,
                      conf: ["default"],
                      arg: 1
                Chain 2:
                  <id:ID> pending
                    arguments:
                      orocos_name: "task",
                      read_only: false,
                      conf: ["default"],
                      arg: 2
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end

        it "properly sets up the merge solver to compute the failed chains" do
            # Originally, the merge solver was NOT setup with early_deploy set,
            # which led the exception to fail on pretty printing in case the merge
            # was OK with early_deploy: false
            #
            # This essentially happens if the conflict appears because of an
            # input that is not deployed
            input_task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            @cmp_m.add input_task_m, as: "input"
            @cmp_m.input_child.connect_to @cmp_m.task_child
            profile = Actions::Profile.new("Test")
            profile.define("test1", @cmp_m)
            profile.define("test2", @cmp_m)

            error_handler = NetworkGeneration::ResolutionErrorHandler.new(
                net_gen.plan, net_gen.merge_solver
            )
            net_gen.compute_system_network(
                [profile.test1_def, profile.test2_def],
                error_handler: error_handler
            )
            failure = error_handler.resolution_failures.find do
                _1.original_exception.kind_of?(ConflictingDeploymentAllocation)
            end
            e = failure.original_exception
            assert e
            formatted = PP.pp(e, +"")

            expected = <<~PP.chomp
                deployed task 'task' from deployment \
                'task' defined in '' on \
                'stubs' is assigned to 2 tasks. Below is the list of \
                the dependent non-deployed actions. Right after the list is \
                a detailed explanation of why the first two tasks are not merged:
                <id:ID>(conf: ["default"], \
                orocos_name: task, read_only: false) is needed by the following definitions:
                  Test.test1_def
                <id:ID>(conf: ["default"], \
                orocos_name: task, read_only: false) is needed by the following definitions:
                  Test.test2_def
                Chain 1 cannot be merged in chain 2:
                Chain 1:
                  <id:ID> pending
                    arguments:
                      orocos_name: "task",
                      read_only: false,
                      conf: ["default"]
                  sink in_port connected via policy {} to source out_port of
                  <id:ID> pending
                    arguments:
                      conf: ["default"],
                      read_only: false
                Chain 2:
                  <id:ID> pending
                    arguments:
                      orocos_name: "task",
                      read_only: false,
                      conf: ["default"]
                  sink in_port connected via policy {} to source out_port of
                  <id:ID> pending
                    arguments:
                      conf: ["default"],
                      read_only: false
            PP
            assert_equal expected, formatted.gsub(/<id:\d+>/, "<id:ID>").chomp
        end
    end

    describe DeployedOnDisabledProcessManager do
        it "pretty-prints itself" do
            task0 = flexmock
            task0.should_receive(:pretty_print).and_return { |pp| pp.text "task0" }
            deployment_task = flexmock(arguments: { on: "manager" })
            error = DeployedOnDisabledProcessManager.new(task0, deployment_task)
            formatted = PP.pp(error, +"", 5)
            expected = <<~PP
                the following task was deployed on manager, which is currently disabled
                task0
            PP
            assert_equal expected, formatted
        end
    end
end
