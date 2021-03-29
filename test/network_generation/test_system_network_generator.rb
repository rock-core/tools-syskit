# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module NetworkGeneration
        describe SystemNetworkGenerator do
            describe "#instanciate" do
                attr_reader :component_m, :requirements
                before do
                    @component_m = Syskit::Component.new_submodel
                    @requirements = component_m.to_instance_requirements
                end

                subject { SystemNetworkGenerator.new(Roby::Plan.new) }

                it "adds instanciated tasks as permanent tasks" do
                    flexmock(requirements).should_receive(:instanciate)
                                          .and_return(instanciated_task = component_m.new)
                    subject.instanciate([requirements])
                    assert subject.plan.permanent_task?(instanciated_task)
                end
                it "returns the list of toplevel tasks in the same order than the requirements" do
                    flexmock(requirements).should_receive(:instanciate)
                                          .and_return(task0 = component_m.new, task1 = component_m.new)
                    assert_equal [task0, task1], subject.instanciate([requirements, requirements])
                end
                it "allocates devices using the task instance requirement information" do
                    dev_m = Device.new_submodel
                    cmp_m = Composition.new_submodel
                    task_m = TaskContext.new_submodel
                    task_m.driver_for dev_m, as: "device"
                    cmp_m.add task_m, as: "test"
                    device = robot.device dev_m, as: "test"
                    cmp = subject.instanciate([cmp_m.use(device)]).first
                    assert_equal device, cmp.test_child.device_dev
                end
                it "sets the task's fullfilled model to the instance requirement's" do
                    task_m = Syskit::TaskContext.new_submodel
                    task_m.argument :arg
                    task = subject.instanciate([task_m.with_arguments(arg: 10)]).first
                    assert_equal [[task_m, AbstractComponent], Hash[arg: 10]],
                                 task.fullfilled_model
                end
                it "only sets the arguments that are meaningful to the task" do
                    task_m = Syskit::TaskContext.new_submodel
                    task_m.argument :arg
                    task = subject.instanciate(
                        [task_m.with_arguments(arg: 10, other: 20)]
                    ).first
                    assert_equal [[task_m, AbstractComponent], Hash[arg: 10]],
                                 task.fullfilled_model
                end
                it "use the arguments as filtered by the task in #fullfilled_model" do
                    task_m = Syskit::TaskContext.new_submodel
                    task_m.argument :arg
                    task_m.class_eval do
                        def arg=(value)
                            arguments[:arg] = value / 2
                        end
                    end
                    task = subject.instanciate([task_m.with_arguments(arg: 10)]).first
                    assert_equal 5, task.arg
                    assert_equal [[task_m, Syskit::AbstractComponent], Hash[arg: 5]],
                                 task.fullfilled_model
                end
            end

            describe "#allocate_devices" do
                attr_reader :dev_m, :task_m, :cmp_m, :device, :cmp, :task
                before do
                    dev_m = @dev_m = Syskit::Device.new_submodel name: "Driver"
                    @task_m = Syskit::TaskContext.new_submodel(name: "Task") { driver_for dev_m, as: "driver" }
                    @cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add task_m, as: "test"
                    @device = robot.device dev_m, as: "d"
                    @cmp = cmp_m.instanciate(plan)
                    @task = cmp.test_child
                end

                subject { SystemNetworkGenerator.new(Roby::ExecutablePlan.new) }
                it "sets missing devices from its selections" do
                    task.requirements.push_dependency_injection(Syskit::DependencyInjection.new(dev_m => device))
                    subject.allocate_devices(task)
                    assert_equal device, task.find_device_attached_to(task.driver_srv)
                end
                it "sets missing devices from the selections in its parent(s)" do
                    cmp.requirements.merge(cmp_m.use(dev_m => device))
                    subject.allocate_devices(task)
                    assert_equal device, task.find_device_attached_to(task.driver_srv)
                end
                it "does not override already set devices" do
                    dev2 = robot.device dev_m, as: "d2"
                    task.arguments[:driver_dev] = dev2
                    cmp.requirements.merge(cmp_m.use(dev_m => device))
                    subject.allocate_devices(task)
                    assert_equal dev2, task.find_device_attached_to(task.driver_srv)
                end
            end

            describe "#compute_system_network" do
                it "runs the validate_abstract_network handler if asked to" do
                    generator = SystemNetworkGenerator.new(plan)
                    flexmock(generator).should_receive(:validate_abstract_network).once
                    generator.compute_system_network([], validate_abstract_network: true)
                end
                it "runs the validate_generated_network handler if asked to" do
                    generator = SystemNetworkGenerator.new(plan)
                    flexmock(generator).should_receive(:validate_generated_network).once
                    generator.compute_system_network([], validate_generated_network: true)
                end
            end

            describe "#generate" do
                describe "handling of optional dependencies" do
                    attr_reader :cmp_m, :srv_m, :task_m, :syskit_engine
                    before do
                        @srv_m = Syskit::DataService.new_submodel
                        @cmp_m = Syskit::Composition.new_submodel
                        cmp_m.add_optional srv_m, as: "test"
                        @task_m = Syskit::TaskContext.new_submodel
                        task_m.provides srv_m, as: "test"
                    end

                    subject { SystemNetworkGenerator.new(plan) }

                    def compute_system_network(*requirements)
                        requirements = requirements.map(&:to_instance_requirements)
                        execute { subject.compute_system_network(requirements, validate_generated_network: false) }
                        cmp = subject.plan.find_tasks(cmp_m).to_a
                        assert_equal 1, cmp.size
                        cmp.first
                    end

                    it "keeps the compositions' optional dependencies that are not abstract" do
                        cmp = compute_system_network(cmp_m.use("test" => task_m))
                        assert cmp.has_role?("test")
                    end
                    it "keeps the compositions' non-optional dependencies that are abstract" do
                        cmp_m.add srv_m, as: "non_optional"
                        cmp = compute_system_network(cmp_m)
                        assert cmp.has_role?("non_optional")
                    end
                    it "removes the compositions' optional dependencies that are still abstract" do
                        cmp = compute_system_network(cmp_m)
                        assert !cmp.has_role?("test")
                    end
                    it "enables the use of the abstract flag in InstanceRequirements to use an optional dep only if it is instanciated by other means" do
                        cmp = compute_system_network(cmp_m.use("test" => task_m.to_instance_requirements.abstract))
                        refute cmp.has_role?("test")
                        execute { plan.remove_task(cmp) }
                        cmp = compute_system_network(cmp_m.use("test" => task_m.to_instance_requirements.abstract), task_m)
                        assert cmp.has_role?("test")
                    end
                end
            end

            describe "#validate_generated_network" do
                it "validates that there are no placeholder tasks left in the plan" do
                    srv_m = Syskit::DataService.new_submodel
                    plan.add(task = Models::Placeholder.create_for([srv_m]).new)
                    assert_raises(Syskit::TaskAllocationFailed) do
                        SystemNetworkGenerator.new(plan).validate_generated_network
                    end
                end
            end

            describe "#verify_no_multiplexing_connections" do
                it "does not raise if the same component can be reached through different paths" do
                    task_m = Syskit::TaskContext.new_submodel do
                        input_port "in", "/double"
                        output_port "out", "/double"
                    end
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add task_m, as: "test"
                    cmp_m.export cmp_m.test_child.out_port

                    cmp0 = cmp_m.instanciate(plan)
                    cmp1 = cmp_m.instanciate(plan)
                    plan.replace_task(cmp1.test_child, cmp0.test_child)
                    plan.add(task = task_m.new)
                    cmp0.out_port.connect_to task.in_port
                    cmp1.out_port.connect_to task.in_port
                    SystemNetworkGenerator.verify_no_multiplexing_connections(plan)
                end
            end
        end
    end
end
