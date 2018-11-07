require 'syskit/test/self'

module Syskit
    module NetworkGeneration
        describe SystemNetworkDeployer do
            attr_reader :deployer
            attr_reader :merge_solver

            attr_reader :deployment_m
            attr_reader :default_deployment_group
            attr_reader :template_group
            attr_reader :template_configured_deployment

            before do
                @default_deployment_group = Models::DeploymentGroup.new
                @deployer = SystemNetworkDeployer.new(plan, default_deployment_group: default_deployment_group)

                @merge_solver = flexmock(deployer.merge_solver)
                @deployment_m = Syskit::Deployment.new_submodel
                @template_group = Models::DeploymentGroup.new
                @template_configured_deployment =
                    Models::ConfiguredDeployment.new('test-mng', deployment_m, Hash['task' => 'task'])
                template_group.register_configured_deployment(template_configured_deployment)
            end

            describe "#propagate_deployment_groups" do
                attr_reader :parent, :child
                before do
                    task_m = Syskit::TaskContext.new_submodel
                    plan.add(@parent = task_m.new)
                    plan.add(@child = task_m.new)
                    parent.depends_on child, role: 'test'
                end

                def assert_has_merged_template_group(selection, child)
                    assert_equal Set[template_configured_deployment],
                        selection[child].find_all_deployments_from_process_manager('test-mng')
                end

                it "propagates the group from parent to child" do
                    parent.requirements.deployment_group.
                        use_group(template_group)
                    selection = deployer.propagate_deployment_groups
                    assert_has_merged_template_group selection, child
                end
                it "ignores plain roby tasks present as root" do
                    plan.add(task = Roby::Task.new)
                    task.depends_on child
                    deployer.propagate_deployment_groups
                end
                it "ignores plain roby tasks present as child" do
                    plan.add(task = Roby::Task.new)
                    parent.depends_on task
                    deployer.propagate_deployment_groups
                end

                it "computes the deployment group for tasks that are not present in the dependency graph" do
                    plan.add(task = Syskit::TaskContext.new_submodel.new)
                    groups = deployer.propagate_deployment_groups
                    assert groups[task]
                end

                it "selects a task's group if it has an explicit one" do
                    child.requirements.deployment_group.
                        use_group(template_group)
                    selection = deployer.propagate_deployment_groups
                    assert_same child.requirements.deployment_group,
                        selection[child]
                end
                it "uses the default deployment group for toplevel tasks that have no group" do
                    default_deployment_group.use_group(template_group)
                    selection = deployer.propagate_deployment_groups
                    assert_has_merged_template_group selection, parent
                    assert_has_merged_template_group selection, child
                end

                it "handles having roots that are not components" do
                    plan.add(root = Roby::Task.new)
                    root.depends_on parent
                    selection = deployer.propagate_deployment_groups
                    assert_same default_deployment_group, selection[child]
                end

                describe "propagation with multiple parents" do
                    attr_reader :task_m
                    attr_reader :other_parent, :other_deployment
                    before do
                        @task_m = Syskit::TaskContext.new_submodel
                        parent.requirements.deployment_group.
                            use_group(template_group)
                        plan.add(@other_parent = task_m.new)
                        @other_deployment =
                            Models::ConfiguredDeployment.new('test-mng', deployment_m, Hash['task' => 'other'])
                        other_parent.requirements.deployment_group.
                            register_configured_deployment(other_deployment)
                        other_parent.depends_on child, role: 'other'
                    end

                    it "merges groups coming from two independent branches" do
                        selection = deployer.propagate_deployment_groups
                        assert_equal Set[other_deployment, template_configured_deployment],
                            selection[child].find_all_deployments_from_process_manager('test-mng')
                    end

                    it "merges groups coming from a diamond" do
                        plan.add(root = task_m.new)
                        root.depends_on parent
                        root.depends_on other_parent
                        selection = deployer.propagate_deployment_groups
                        assert_equal Set[other_deployment, template_configured_deployment],
                            selection[child].find_all_deployments_from_process_manager('test-mng')
                    end

                    it "keeps the parent groups independent" do
                        selection = deployer.propagate_deployment_groups
                        refute_same selection[parent], selection[child]
                        refute_same selection[other_parent], selection[child]
                    end

                    it "propagates both branches to granchildren" do
                        plan.add(grandchild = task_m.new)
                        child.depends_on grandchild, role: 'deeper'
                        # Must use_cow: false here, otherwise the test set up is
                        # super fragile. We really want to be sure that the
                        # algorithm goes over all tasks
                        selection = deployer.propagate_deployment_groups(use_cow: false)
                        assert_equal Set[other_deployment, template_configured_deployment],
                            selection[grandchild].find_all_deployments_from_process_manager('test-mng')
                    end

                    it "does not merge the default deployments into intermediate tasks with no specific requirements" do
                        # ORDER MATTERS HERE. The issue is with RGL's default
                        # depth first visit implementation, which picks the
                        # vertices one by one in order
                        execute { plan.clear }
                        plan.add(child = task_m.new)
                        plan.task_relation_graph_for(Roby::TaskStructure::Dependency).add_vertex(child)
                        plan.add(parent = task_m.new)
                        parent.depends_on child
                        parent.requirements.use_deployment(deployment_m)
                        selection = deployer.propagate_deployment_groups
                        assert_equal parent.requirements.deployment_group, selection[child]
                    end
                end
            end

            describe "#resolve_deployment_ambiguity" do
                def mock_configured_deployment
                    flexmock(process_server_name: 'test-mng')
                end

                it "resolves ambiguity by orocos_name" do
                    candidates = [[mock_configured_deployment, 'task'], [mock_configured_deployment, 'other_task']]
                    assert_equal candidates[1],
                        deployer.resolve_deployment_ambiguity(candidates, flexmock(orocos_name: 'other_task'))
                end
                it "returns nil if the requested orocos_name cannot be found" do
                    candidates = [[mock_configured_deployment, 'task']]
                    refute deployer.resolve_deployment_ambiguity(candidates, flexmock(orocos_name: 'other_task'))
                end
                it "resolves ambiguity by deployment hints if there are no name" do
                    candidates = [[mock_configured_deployment, 'task'], [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [/other/])
                    assert_equal candidates[1],
                        deployer.resolve_deployment_ambiguity(candidates, task)
                end
                it "returns nil if there are neither an orocos name nor hints" do
                    candidates = [[mock_configured_deployment, 'task'], [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [], model: nil)
                    assert !deployer.resolve_deployment_ambiguity(candidates, task)
                end
                it "returns nil if the hints don't allow to resolve the ambiguity" do
                    candidates = [[mock_configured_deployment, 'task'], [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [/^other/, /^task/], model: nil)
                    assert !deployer.resolve_deployment_ambiguity(candidates, task)
                end
            end

            describe "#select_deployments" do
                attr_reader :task_m, :task, :task_models, :deployments, :deployment_models
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    plan.add(@task = task_m.new)

                    @deployment_models = [Syskit::Deployment.new_submodel, Syskit::Deployment.new_submodel]
                    @task_models = [Syskit::TaskContext.new_submodel, Syskit::TaskContext.new_submodel]
                    @deployments = Hash[
                        task_models[0] => [['machine', deployment_models[0], 'task']],
                        task_models[1] => [['other_machine', deployment_models[1], 'other_task']]
                    ]
                    deployment_models[0].orogen_model.task 'task', task_models[0].orogen_model
                    deployment_models[1].orogen_model.task 'other_task', task_models[1].orogen_model
                end

                it "selects a deployment returned by #find_suitable_deployment_for" do
                    groups = flexmock
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        with(task, groups).
                        and_return(deployment = flexmock)
                    assert_equal [Hash[task => deployment], Set.new],
                        deployer.select_deployments([task], groups)
                end
                it "ignores tasks that already have an execution agent" do
                    flexmock(task).should_receive(:execution_agent).and_return(true)
                    assert_equal [Hash[], Set[]],
                        deployer.select_deployments([task], flexmock)
                end
                it "reports a task that has no deployments in the returned "\
                    "missing_deployments set" do
                    groups = flexmock
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        with(task, groups).
                        and_return(nil)
                    assert_equal [Hash[], Set[task]],
                        deployer.select_deployments([task], groups)
                end
                it "does not select the same deployment twice" do
                    groups = flexmock
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task1 = task_m.new)
                    assert_equal [Hash[task => deployment], Set[task1]],
                        deployer.select_deployments([task, task1], groups)
                end

                it "does not allocate the same task twice" do
                    groups = flexmock
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task0 = task_models[0].new)
                    plan.add(task1 = task_models[0].new)
                    _, missing = deployer.select_deployments([task0, task1], groups)
                    assert_equal 1, missing.size
                    assert [task0, task1].include?(missing.first)
                end
                it "does not resolve ambiguities by considering already allocated tasks" do
                    groups = flexmock
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task0 = task_models[0].new(orocos_name: 'task'))
                    plan.add(task1 = task_models[0].new)
                    _, missing = deployer.select_deployments([task0, task1], groups)
                    assert_equal [task1], missing.to_a
                end
            end

            describe "#find_suitable_deployment_for" do
                attr_reader :task_m, :task
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    plan.add(@task = task_m.new)
                end

                subject do
                    deployer = SystemNetworkDeployer.new(plan)
                    deployer.task_context_deployment_candidates.merge!(deployments)
                    deployer
                end

                it "returns the possible deployment if it is unique" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return([deployment = flexmock])
                    assert_equal deployment, deployer.find_suitable_deployment_for(
                        task, Hash[task => group])
                end
                it "disambiguates tasks that have more than one possible deployments" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return(candidates = [flexmock, deployment1 = flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity).
                        with(candidates, task).
                        and_return(deployment1)
                    assert_equal deployment1, deployer.find_suitable_deployment_for(
                        task, Hash[task => group])
                end
                it "returns nil if the disambiguation failed" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return(candidates = [flexmock, flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity).
                        with(candidates, task).
                        and_return(nil)
                    assert_nil deployer.find_suitable_deployment_for(
                        task, Hash[task => group])
                end
            end

            describe "#deploy" do
                attr_reader :task_models
                attr_reader :deployment_models
                attr_reader :deployment_group

                before do
                    @task_models = task_models = [
                        TaskContext.new_submodel { output_port 'out', '/int32_t' },
                        TaskContext.new_submodel { input_port 'in', '/int32_t' }
                    ]
                    @deployment_models = [
                        Deployment.new_submodel do
                            task 'task', task_models[0].orogen_model
                        end,
                        Deployment.new_submodel do
                            task 'other_task', task_models[1].orogen_model
                        end
                    ]

                    @deployment_group = Models::DeploymentGroup.new
                    @deployment_group.register_configured_deployment(
                        Models::ConfiguredDeployment.new(
                            'machine', deployment_models[0]))
                    @deployment_group.register_configured_deployment(
                        Models::ConfiguredDeployment.new(
                            'other_machine', deployment_models[1]))
                    deployer.default_deployment_group = @deployment_group
                end

                it "applies the known deployments before returning the missing ones" do
                    deployer.default_deployment_group = Models::DeploymentGroup.new
                    plan.add(task0 = task_models[0].new)
                    task0.requirements.use_deployment(deployment_models[0])
                    plan.add(task1 = task_models[1].new)
                    assert_equal Set[task1], execute { deployer.deploy(validate: false) }
                    deployment_task = plan.find_local_tasks(deployment_models[0]).first
                    assert deployment_task
                    assert_equal ['task'], deployment_task.each_executed_task.
                        map(&:orocos_name)
                end

                it "validates the plan if 'validate' is true" do
                    flexmock(deployer).should_receive(:validate_deployed_network).once
                    deployer.deploy
                end

                it "creates the necessary deployment task and uses #task to get the deployed task context" do
                    plan.add(root = Roby::Task.new)
                    root.depends_on(task = task_models[0].new, role: 't')
                    task.requirements.use_deployment(deployment_models[0])
                    assert_equal Set.new, execute { deployer.deploy(validate: false) }
                    refute_equal task, root.t_child
                    assert_equal 'task', root.t_child.orocos_name
                    assert_kind_of deployment_models[0], root.t_child.execution_agent
                end
                it "copies the connections from the tasks to their deployed counterparts" do
                    plan.add(task0 = task_models[0].new)
                    plan.add(task1 = task_models[1].new)
                    task0.out_port.connect_to task1.in_port
                    assert_equal Set.new, execute { deployer.deploy(validate: false) }
                    deployed_task0 = deployer.merge_solver.replacement_for(task0)
                    deployed_task1 = deployer.merge_solver.replacement_for(task1)
                    refute_same task0, deployed_task0
                    refute_same task1, deployed_task1
                    assert deployed_task0.out_port.connected_to?(deployed_task1.in_port)
                end
                it "instanciates the same deployment only once on the same machine" do
                    task_m = TaskContext.new_submodel
                    plan.add(root = Roby::Task.new)
                    root.depends_on(task0 = task_m.new(orocos_name: 't0'), role: 't0')
                    root.depends_on(task1 = task_m.new(orocos_name: 't1'), role: 't1')

                    deployment_m = Deployment.new_submodel do
                        task 't0', task_m.orogen_model
                        task 't1', task_m.orogen_model
                    end

                    task0.requirements.use_configured_deployment(
                        Models::ConfiguredDeployment.new('machine', deployment_m))
                    task1.requirements.use_configured_deployment(
                        Models::ConfiguredDeployment.new('machine', deployment_m))

                    # Create on the right host
                    flexmock(deployment_m).should_receive(:new).
                        with(hsh(on: 'machine')).once.pass_thru
                    # And finally replace the task with the deployed task
                    assert_equal Set.new, execute { deployer.deploy(validate: false) }
                    refute_equal root.t0_child, task0
                    refute_equal root.t1_child, task1
                    assert_kind_of deployment_m, root.t0_child.execution_agent
                    assert_equal root.t0_child.execution_agent,
                        root.t1_child.execution_agent
                end
            end

            describe "#validate_deployed_network" do
                it "raises if some tasks are not deployed" do
                    task_m = Syskit::TaskContext.new_submodel
                    deployment_m.orogen_model.task 'task', task_m.orogen_model
                    plan.add(task = task_m.new)
                    groups = Hash[task => template_group]
                    assert_raises(MissingDeployments) do
                        deployer.validate_deployed_network(groups)
                    end
                end
            end
        end
    end
end
