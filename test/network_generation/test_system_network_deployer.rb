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
                        plan.clear
                        plan.add(child = task_m.new)
                        plan.task_relation_graph_for(Roby::TaskStructure::Dependency).add_vertex(child)
                        plan.add(parent = task_m.new)
                        parent.depends_on child
                        configured_deployment = parent.requirements.use_deployment(deployment_m)
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
                attr_reader :task_m, :task
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    plan.add(@task = task_m.new)
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
                it "registers a task that has no deployments in the missing_deployments return set" do
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
            end

            describe "#find_suitable_deployment_for" do
                attr_reader :task_m, :task
                before do
                    @task_m = Syskit::TaskContext.new_submodel
                    plan.add(@task = task_m.new)
                end

                it "returns the possible deployment if it is unique" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return([deployment = flexmock])
                    assert_equal deployment, deployer.find_suitable_deployment_for(task, Hash[task => group])
                end
                it "disambiguates tasks that have more than one possible deployments" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return(candidates = [deployment0 = flexmock, deployment1 = flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity).
                        with(candidates, task).
                        and_return(deployment1)
                    assert_equal deployment1, deployer.find_suitable_deployment_for(task, Hash[task => group])
                end
                it "returns nil if the disambiguation failed" do
                    group = flexmock(:on, Models::DeploymentGroup)
                    group.should_receive(:find_all_suitable_deployments_for).with(task).
                        and_return(candidates = [deployment0 = flexmock, deployment1 = flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity).
                        with(candidates, task).
                        and_return(nil)
                    assert_equal nil, deployer.find_suitable_deployment_for(task, Hash[task => group])
                end
            end

            describe "#deploy" do
                attr_reader :task0_m, :deployment0_m
                attr_reader :task1_m, :deployment1_m
                before do
                    @task0_m = Syskit::TaskContext.new_submodel
                    @task1_m = Syskit::TaskContext.new_submodel
                    @deployment0_m = Syskit::Deployment.new_submodel
                    deployment0_m.orogen_model.task 'task0', task0_m.orogen_model
                    @deployment1_m = Syskit::Deployment.new_submodel
                    deployment1_m.orogen_model.task 'task1', task1_m.orogen_model

                    @deployment_group = Syskit::Models::DeploymentGroup.new
                end

                it "applies the known deployments before returning the missing ones" do
                    plan.add(task0 = task0_m.new)
                    task0_srv = task0.as_service
                    task0.requirements.use_deployment(deployment0_m)
                    plan.add(task1 = task1_m.new)
                    assert_equal Set[task1], deployer.deploy(validate: false)
                    assert(deployment_task = plan.find_local_tasks(deployment0_m).first)
                    assert_equal ['task0'], deployment_task.each_executed_task.map(&:orocos_name)
                end

                it "validates the plan if 'validate' is true" do
                    flexmock(deployer).should_receive(:validate_deployed_network).once
                    deployer.deploy
                end

                it "creates the necessary deployment task and uses #task to get the deployed task context" do
                    plan.add(task = task0_m.new)
                    task.requirements.use_deployment(deployment0_m)
                    # Create on the right host
                    flexmock(deployment0_m).should_receive(:new).once.
                        and_return(deployment_task = flexmock(Roby::Task.new))
                    # Add it to the work plan
                    flexmock(plan).should_receive(:add).once.with([deployment_task]).ordered.pass_thru
                    # Create the task
                    deployment_task.should_receive(:task).explicitly.
                        with('task0').and_return(deployed_task = flexmock).ordered
                    # And finally replace the task with the deployed task
                    merge_solver.should_receive(:apply_merge_group).once.with(task => deployed_task)
                    deployer.deploy(validate: false)
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

