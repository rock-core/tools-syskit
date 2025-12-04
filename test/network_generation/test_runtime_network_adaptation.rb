# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

module Syskit
    module NetworkGeneration
        describe RuntimeNetworkAdaptation do
            include Syskit::Fixtures::SimpleCompositionModel

            attr_reader :work_plan, :merge_solver

            before do
                @work_plan = Roby::Transaction.new(plan)
                @merge_solver = MergeSolver.new(@work_plan)
                @task_models = 5.times.map { TaskContext.new_submodel }
            end

            describe "#finalize_deployed_tasks" do
                describe "eagerly deployed networks" do
                    it "replaces existing tasks by their match in the plan" do
                        deployment_m = create_deployment_model(task_count: 1)
                        _, initial =
                            add_deployment_and_tasks(work_plan, deployment_m, %w[task0])
                        adapter = create_adapter(
                            used_deployments_from_tasks(initial)
                        )

                        existing_deployment, =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0])

                        selected_deployments, = adapter.finalize_deployed_tasks
                        assert_equal [work_plan[existing_deployment]],
                                     selected_deployments.to_a
                    end

                    it "ignores existing deployments " \
                       "that are not needed by the network" do
                        deployment_m = create_deployment_model(task_count: 1)
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])

                        adapter = create_adapter({})
                        selected_deployments, = adapter.finalize_deployed_tasks
                        assert selected_deployments.empty?
                    end

                    it "creates a new deployment if needed" do
                        deployment = create_deployment_model(task_count: 2)
                        required_deployment, tasks =
                            add_deployment_and_tasks(work_plan, deployment,
                                                     %w[task0 task1])
                        adapter = create_adapter(
                            used_deployments_from_tasks(tasks)
                        )

                        selected_deployments, selected_deployed_tasks =
                            adapter.finalize_deployed_tasks

                        assert_equal [required_deployment], selected_deployments.to_a
                        selected_deployed_tasks.each do |t|
                            assert_equal t.execution_agent, required_deployment
                        end
                    end

                    it "updates an existing deployment, proxying the existing " \
                       "tasks and creating new ones" do
                        deployment_m = create_deployment_model(task_count: 3)
                        existing_deployment, (task0, task1) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])
                        _, (required0, task2) =
                            add_deployment_and_tasks(
                                work_plan, deployment_m, %w[task0 task2]
                            )

                        adapter = create_adapter(
                            used_deployments_from_tasks([required0, task2])
                        )

                        selected_deployments, selected_deployed_tasks =
                            adapter.finalize_deployed_tasks

                        expected_deployment = work_plan[existing_deployment]
                        assert_equal [expected_deployment], selected_deployments.to_a

                        task2 = work_plan.find_local_tasks
                                         .with_arguments(orocos_name: "task2").first
                        assert task2
                        refute task2.transaction_proxy?

                        assert_equal [work_plan[task0], work_plan[task1], task2].to_set,
                                     expected_deployment.each_executed_task.to_set
                        assert_equal [work_plan[task0], task2].to_set,
                                     selected_deployed_tasks.to_set
                    end

                    it "maintains the dependencies" do
                        deployment_m = create_deployment_model(task_count: 2)
                        _, (existing0, existing1) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])

                        _, (required0, required1) =
                            add_deployment_and_tasks(
                                work_plan, deployment_m, %w[task0 task1]
                            )

                        existing0.depends_on(existing1)

                        adapter = create_adapter(
                            used_deployments_from_tasks([required0, required1])
                        )
                        adapter.finalize_deployed_tasks

                        assert work_plan[existing0].depends_on?(work_plan[existing1])
                    end

                    it "maintains the dependencies with two or more layers" do
                        deployment_m = create_deployment_model(task_count: 3)
                        _, (existing0,) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0])

                        _, (required0, required1, required2) =
                            add_deployment_and_tasks(work_plan, deployment_m,
                                                     %w[task0 task1 task2])

                        required0.depends_on required2
                        required1.depends_on required2

                        adapter = create_adapter(
                            used_deployments_from_tasks([required0, required1, required2])
                        )
                        adapter.finalize_deployed_tasks

                        required2 = work_plan[existing0].children.first
                        assert_equal "task2", required2.orocos_name
                        assert(required2.each_parent_task
                                        .find { |t| t.orocos_name == "task1" })
                    end

                    it "raises if there is a repeated deployment" do
                        deployment_m = create_deployment_model(task_count: 1)
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])
                        _, tasks =
                            add_deployment_and_tasks(work_plan, deployment_m, %w[task0])

                        adapter = create_adapter(used_deployments_from_tasks(tasks))
                        assert_raises Syskit::InternalError do
                            adapter.finalize_deployed_tasks
                        end
                    end
                end

                describe "lazily deployed networks" do
                    it "replaces existing tasks by their match in the plan" do
                        deployment_m = create_deployment_model(task_count: 1)
                        existing_deployment, =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0])
                        initial = add_lazy_tasks(work_plan, deployment_m, %w[task0])
                        adapter = create_adapter(
                            used_deployments_from_lazy(initial, deployment_m)
                        )

                        selected_deployments, = adapter.finalize_deployed_tasks
                        assert_equal [work_plan[existing_deployment]],
                                     selected_deployments.to_a
                    end

                    it "ignores existing deployments " \
                       "that are not needed by the network" do
                        deployment_m = create_deployment_model(task_count: 1)
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])

                        adapter = create_adapter({})
                        selected_deployments, = adapter.finalize_deployed_tasks
                        assert selected_deployments.empty?
                    end

                    it "creates a new deployment if needed" do
                        deployment_m = create_deployment_model(task_count: 2)
                        tasks = add_lazy_tasks(work_plan, deployment_m, %w[task0 task1])
                        adapter = create_adapter(
                            used_deployments_from_lazy(tasks, deployment_m)
                        )

                        selected_deployments, =
                            adapter.finalize_deployed_tasks

                        assert_equal 1, selected_deployments.size
                        task_names =
                            selected_deployments
                            .first.each_executed_task.map(&:orocos_name).sort
                        assert_equal %w[task0 task1], task_names
                    end

                    it "updates an existing deployment, proxying the existing " \
                       "tasks and creating new ones" do
                        deployment_m = create_deployment_model(task_count: 3)
                        existing_deployment, (task0, task1) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])
                        (required0, task2) = add_lazy_tasks(
                            work_plan, deployment_m, %w[task0 task2]
                        )

                        adapter = create_adapter(
                            used_deployments_from_lazy([required0, task2], deployment_m)
                        )

                        selected_deployments, selected_deployed_tasks =
                            adapter.finalize_deployed_tasks

                        expected_deployment = work_plan[existing_deployment]
                        assert_equal [expected_deployment], selected_deployments.to_a

                        task2 = work_plan.find_local_tasks
                                         .with_arguments(orocos_name: "task2").first
                        assert task2
                        refute task2.transaction_proxy?

                        assert_equal [work_plan[task0], work_plan[task1], task2].to_set,
                                     expected_deployment.each_executed_task.to_set
                        assert_equal [work_plan[task0], task2].to_set,
                                     selected_deployed_tasks.to_set
                    end

                    it "maintains the dependencies" do
                        deployment_m = create_deployment_model(task_count: 2)
                        _, (existing0, existing1) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0 task1])

                        (required0, required1) = add_lazy_tasks(
                            work_plan, deployment_m, %w[task0 task1]
                        )

                        existing0.depends_on(existing1)

                        adapter = create_adapter(
                            used_deployments_from_lazy(
                                [required0, required1], deployment_m
                            )
                        )
                        adapter.finalize_deployed_tasks

                        assert work_plan[existing0].depends_on?(work_plan[existing1])
                    end

                    it "maintains the dependencies with two or more layers" do
                        deployment_m = create_deployment_model(task_count: 3)
                        _, (existing0,) =
                            add_deployment_and_tasks(plan, deployment_m, %w[task0])

                        (required0, required1, required2) =
                            add_lazy_tasks(work_plan, deployment_m, %w[task0 task1 task2])

                        required0.depends_on required2
                        required1.depends_on required2

                        adapter = create_adapter(
                            used_deployments_from_lazy(
                                [required0, required1, required2], deployment_m
                            )
                        )
                        adapter.finalize_deployed_tasks

                        required2 = work_plan[existing0].children.first
                        assert_equal "task2", required2.orocos_name
                        assert(required2.each_parent_task
                                        .find { |t| t.orocos_name == "task1" })
                    end

                    it "raises if there is a repeated deployment" do
                        deployment_m = create_deployment_model(task_count: 1)
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])
                        add_deployment_and_tasks(plan, deployment_m, %w[task0])
                        tasks = add_lazy_tasks(work_plan, deployment_m, %w[task0])

                        adapter = create_adapter(
                            used_deployments_from_lazy(tasks, deployment_m)
                        )
                        assert_raises Syskit::InternalError do
                            adapter.finalize_deployed_tasks
                        end
                    end
                end

                def create_deployment_model(task_count:)
                    if task_count > @task_models.size
                        raise ArgumentError,
                              "only provisioned #{@task_models.size} models"
                    end

                    task_models = @task_models
                    Deployment.new_submodel do
                        task_count.times { |i| task "task#{i}", task_models[i] }
                    end
                end

                def add_deployment_and_tasks(plan, deployment_m, task_names)
                    plan.add(deployment_task = deployment_m.new)
                    tasks = task_names.map { |name| deployment_task.task(name) }
                    [deployment_task, tasks]
                end

                def add_lazy_tasks(plan, deployment_m, task_names)
                    tasks = task_names.each_with_index.map do |name, _i|
                        deployment_m.task(name).new(orocos_name: name)
                    end
                    plan.add(tasks)
                    tasks
                end
            end

            describe "#reconfigure_tasks_on_static_port_modification" do
                before do
                    @adapter = RuntimeNetworkAdaptation.new(
                        @work_plan, {}, merge_solver: @merge_solver
                    )
                end

                it "reconfigures already-configured tasks " \
                   "whose static input ports have been modified" do
                    task = syskit_stub_deploy_and_configure("Task", as: "task") do
                        input_port("in", "/double").static
                    end
                    proxy = work_plan[task]
                    flexmock(proxy)
                        .should_receive(:transaction_modifies_static_ports?)
                        .once.and_return(true)
                    @adapter.reconfigure_tasks_on_static_port_modification([proxy])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal 2, tasks.size
                    tasks.delete(proxy)
                    new_task = tasks.first

                    assert_child_of proxy.stop_event, new_task.start_event,
                                    Roby::EventStructure::SyskitConfigurationPrecedence
                end

                it "does not reconfigure already-configured tasks " \
                   "whose static input ports have not been modified" do
                    task = syskit_stub_deploy_and_configure("Task", as: "task") do
                        input_port("in", "/double").static
                    end
                    proxy = work_plan[task]
                    flexmock(proxy).should_receive(:transaction_modifies_static_ports?)
                                   .once.and_return(false)
                    @adapter.reconfigure_tasks_on_static_port_modification([proxy])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal work_plan.wrap([task]), tasks
                end

                it "does not reconfigure not-setup tasks" do
                    task = syskit_stub_and_deploy("Task") do
                        input_port("in", "/double").static
                    end
                    @adapter.reconfigure_tasks_on_static_port_modification([task])
                    tasks = work_plan.find_local_tasks(Syskit::TaskContext)
                                     .with_arguments(orocos_name: task.orocos_name).to_a
                    assert_equal work_plan.wrap([task]), tasks
                end
            end

            describe "#adapt_existing_deployment" do
                attr_reader :task_m, :deployment_m
                attr_reader :deployment_task, :existing_deployment_task
                # All the merges that happened during a given test
                attr_reader :applied_merge_mappings

                before do
                    task_m = @task_m = Syskit::Component.new_submodel do
                        argument :orocos_name
                        argument :conf
                    end

                    @applied_merge_mappings = {}
                    existing_deployment_task = EngineTestStubDeployment.new(task_m)
                    plan.add(existing_deployment_task)
                    @existing_deployment_task = work_plan[existing_deployment_task]
                    flexmock(@merge_solver)
                        .should_receive(:apply_merge_group)
                        .with(
                            lambda do |mappings|
                                applied_merge_mappings.merge!(mappings)
                                true
                            end
                        )
                        .pass_thru
                    work_plan.add(@deployment_task = EngineTestStubDeployment.new(task_m))
                    @adapter = RuntimeNetworkAdaptation.new(
                        @work_plan, {}, merge_solver: @merge_solver
                    )
                end

                it "creates a new deployed task if there is not one already" do
                    task = deployment_task.task "test"
                    @adapter.adapt_existing_deployment(deployment_task,
                                                       existing_deployment_task)
                    created_task = existing_deployment_task.created_tasks[0].last
                    assert_equal [["test", task_m, created_task]],
                                 existing_deployment_task.created_tasks
                    assert_equal({ task => created_task }, applied_merge_mappings)
                end

                it "reuses an existing deployment" do
                    existing_task = existing_deployment_task.task("test", record: false)
                    task = deployment_task.task "test"
                    @adapter.adapt_existing_deployment(deployment_task,
                                                       existing_deployment_task)
                    assert existing_deployment_task.created_tasks.empty?
                    assert_equal({ task => existing_task }, applied_merge_mappings)
                end

                describe "there is a deployment and it cannot be reused" do
                    attr_reader :task, :existing_task

                    before do
                        @existing_task = existing_deployment_task.task("test",
                                                                       record: false)
                        @task = deployment_task.task "test"
                        flexmock(task).should_receive(:can_be_deployed_by?)
                                      .with(existing_task).and_return(false)
                    end

                    it "creates a new deployed task" do
                        @adapter.adapt_existing_deployment(deployment_task,
                                                           existing_deployment_task)
                        created_task = existing_deployment_task.created_tasks[0].last
                        assert_equal [["test", task_m, created_task]],
                                     existing_deployment_task.created_tasks
                        assert_equal({ task => created_task }, applied_merge_mappings)
                    end
                    it "synchronizes the newly created task " \
                       "with the end of the existing one" do
                        @adapter.adapt_existing_deployment(deployment_task,
                                                           existing_deployment_task)
                        created_task = existing_deployment_task.created_tasks[0].last
                        assert_has_precedence(
                            [created_task.start_event], existing_task.stop_event
                        )
                    end
                    it "re-synchronizes with all the existing tasks " \
                       "if more than one is present at a given time" do
                        @adapter.adapt_existing_deployment(deployment_task,
                                                           existing_deployment_task)
                        first_new_task = existing_deployment_task.created_tasks[0].last

                        deployment_task = EngineTestStubDeployment.new(task_m)
                        work_plan.add(deployment_task)
                        task = deployment_task.task("test")
                        flexmock(task).should_receive(:can_be_deployed_by?)
                                      .with(first_new_task).and_return(false)
                        @adapter.adapt_existing_deployment(deployment_task,
                                                           existing_deployment_task)
                        second_new_task = existing_deployment_task.created_tasks[1].last

                        assert_has_precedence(
                            [first_new_task.start_event, second_new_task.start_event],
                            existing_task.stop_event
                        )
                        assert_has_precedence(
                            [second_new_task.start_event], first_new_task.stop_event
                        )
                    end

                    it "synchronizes with the existing tasks " \
                       "even if there are no current ones" do
                        flexmock(@adapter).should_receive(:find_current_deployed_task)
                                          .once.and_return(nil)
                        @adapter.adapt_existing_deployment(
                            deployment_task, existing_deployment_task
                        )
                        created_task = existing_deployment_task.created_tasks[0].last

                        assert_has_precedence(
                            [created_task.start_event], existing_task.stop_event
                        )
                    end
                end
            end

            describe "#find_current_deployed_task" do
                it "returns the 'last' task" do
                    component_m = Syskit::Component.new_submodel
                    plan.add(task0 = component_m.new)
                    plan.add(task1 = component_m.new)
                    task1.should_configure_after(task0.stop_event)
                    task0 = work_plan[task0]
                    task1 = work_plan[task1]
                    adapter = create_adapter([])
                    assert_equal task1, adapter.find_current_deployed_task([task0, task1])
                end

                it "ignores garbage tasks that have not been finalized yet" do
                    component_m = Syskit::Component.new_submodel
                    plan.add(task0 = component_m.new)
                    flexmock(task0).should_receive(can_finalize?: false)
                    plan.add(task1 = component_m.new)
                    task1.should_configure_after(task0.stop_event)
                    execute { plan.garbage_task(task0) }
                    task0 = work_plan[task0]
                    task1 = work_plan[task1]
                    adapter = create_adapter([])
                    assert_equal task1, adapter.find_current_deployed_task([task0, task1])
                end

                it "does not ignore non-reusable tasks" do
                    component_m = Syskit::Component.new_submodel
                    plan.add(task0 = component_m.new)
                    plan.add(task1 = component_m.new)
                    task1.should_configure_after(task0.stop_event)
                    task0.do_not_reuse
                    task1.do_not_reuse
                    task0 = work_plan[task0]
                    task1 = work_plan[task1]
                    adapter = create_adapter([])
                    assert_equal task1, adapter.find_current_deployed_task([task0, task1])
                end
            end

            def create_adapter(used_deployments)
                RuntimeNetworkAdaptation.new(work_plan, used_deployments,
                                             merge_solver: @merge_solver)
            end

            def used_deployments_from_tasks(tasks)
                tasks.each_with_object({}) do |task, used_deployments|
                    used_deployments[task] = flexmock(
                        configured_deployment: flexmock(
                            process_name: task.execution_agent.process_name
                        )
                    )
                end
            end

            def used_deployments_from_lazy(tasks, deployment_m)
                tasks.each_with_object({}) do |task, used_deployments|
                    used_deployments[task] = flexmock(
                        configured_deployment: Models::ConfiguredDeployment.new(
                            "localhost", deployment_m
                        )
                    )
                end
            end

            def assert_has_precedence(preceding_events, event)
                assert_equal preceding_events.to_set,
                             event.each_syskit_configuration_precedence(false).to_set
            end
        end

        class EngineTestStubDeployment < Roby::Task
            attr_reader :tasks, :created_tasks

            def initialize(task_m, **arguments)
                super(**arguments)
                @task_m = task_m
                @created_tasks = []
                @tasks = {}
            end

            event :ready

            define_method :task do |task_name, task_model = nil, record: true|
                task = @task_m.new(orocos_name: task_name)
                @created_tasks << [task_name, task_model, task] if record
                task.executed_by self
                task
            end
        end
    end
end
