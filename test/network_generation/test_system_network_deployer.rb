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
                @deployer = SystemNetworkDeployer.new(
                    plan, default_deployment_group: default_deployment_group
                )

                @merge_solver = flexmock(deployer.merge_solver)
                @deployment_m = Syskit::Deployment.new_submodel
                @template_group = Models::DeploymentGroup.new
                @template_configured_deployment =
                    Models::ConfiguredDeployment.new(
                        'test-mng', deployment_m, 'task' => 'task'
                    )
                template_group.register_configured_deployment(
                    template_configured_deployment
                )
            end

            describe '#resolve_deployment_ambiguity' do
                def mock_configured_deployment
                    flexmock(process_server_name: 'test-mng')
                end

                it 'resolves ambiguity by orocos_name' do
                    candidates = [[mock_configured_deployment, 'task'],
                                  [mock_configured_deployment, 'other_task']]
                    assert_equal(
                        candidates[1],
                        deployer.resolve_deployment_ambiguity(
                            candidates, flexmock(orocos_name: 'other_task')
                        )
                    )
                end
                it 'returns nil if the requested orocos_name cannot be found' do
                    candidates = [[mock_configured_deployment, 'task']]
                    refute deployer.resolve_deployment_ambiguity(
                        candidates, flexmock(orocos_name: 'other_task')
                    )
                end
                it 'resolves ambiguity by deployment hints if there are no name' do
                    candidates = [[mock_configured_deployment, 'task'],
                                  [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [/other/])
                    assert_equal candidates[1],
                                 deployer.resolve_deployment_ambiguity(candidates, task)
                end
                it 'returns nil if there are neither an orocos name nor hints' do
                    candidates = [[mock_configured_deployment, 'task'],
                                  [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [], model: nil)
                    refute deployer.resolve_deployment_ambiguity(candidates, task)
                end
                it 'returns nil if the hints don\'t allow to resolve the ambiguity' do
                    candidates = [[mock_configured_deployment, 'task'],
                                  [mock_configured_deployment, 'other_task']]
                    task = flexmock(orocos_name: nil, model: nil,
                                    deployment_hints: [/^other/, /^task/])
                    refute deployer.resolve_deployment_ambiguity(candidates, task)
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
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        with(task).
                        and_return(deployment = flexmock)
                    assert_equal [Hash[task => deployment], Set.new],
                        deployer.select_deployments([task])
                end
                it "ignores tasks that already have an execution agent" do
                    flexmock(task).should_receive(:execution_agent).and_return(true)
                    assert_equal [Hash[], Set[]],
                        deployer.select_deployments([task])
                end
                it "reports a task that has no deployments in the returned "\
                    "missing_deployments set" do
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        with(task).
                        and_return(nil)
                    assert_equal [Hash[], Set[task]],
                        deployer.select_deployments([task])
                end
                it "does not select the same deployment twice" do
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task1 = task_m.new)
                    assert_equal [Hash[task => deployment], Set[task1]],
                        deployer.select_deployments([task, task1])
                end

                it "does not allocate the same task twice" do
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task0 = task_models[0].new)
                    plan.add(task1 = task_models[0].new)
                    _, missing = deployer.select_deployments([task0, task1])
                    assert_equal 1, missing.size
                    assert [task0, task1].include?(missing.first)
                end
                it "does not resolve ambiguities by considering already allocated tasks" do
                    flexmock(deployer).should_receive(:find_suitable_deployment_for).
                        and_return(deployment = flexmock)
                    plan.add(task0 = task_models[0].new(orocos_name: 'task'))
                    plan.add(task1 = task_models[0].new)
                    _, missing = deployer.select_deployments([task0, task1])
                    assert_equal [task1], missing.to_a
                end
            end

            describe '#find_all_suitable_deployments_for' do
                attr_reader :task_m, :deployment_m

                before do
                    @task_m = Syskit::TaskContext.new_submodel(name: 'Test')
                    @deployment_m = syskit_stub_deployment_model(
                        task_m, 'orogen_default_Test'
                    )
                    @deployer = SystemNetworkDeployer.new(plan)
                end

                it 'returns a deployment stored on the task itself' do
                    task = @task_m.deployed_as('test', on: 'stubs')
                                  .instanciate(plan)

                    deployments = @deployer.find_all_suitable_deployments_for(task)
                    assert_equal 1, deployments.size
                    assert_equal 'test', deployments.first.mapped_task_name
                    assert_equal deployment_m,
                                 deployments.first.configured_deployment.model
                end

                it 'falls back on the default deployment if a standalone task has no suitable deployment' do
                    @deployer.default_deployment_group
                             .use_deployment(@task_m => 'test', on: 'stubs')
                    task = @task_m.instanciate(plan)

                    deployments = @deployer.find_all_suitable_deployments_for(task)
                    assert_equal 1, deployments.size
                    assert_equal 'test', deployments.first.mapped_task_name
                    assert_equal deployment_m,
                                 deployments.first.configured_deployment.model
                end

                it 'returns a deployment stored on the task\'s parent' do
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m, as: 'child'
                    cmp = cmp_m.to_instance_requirements
                               .use_deployment(@task_m => 'test', on: 'stubs')
                               .instanciate(plan)

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp.child_child)
                    assert_equal 1, deployments.size
                    assert_equal 'test', deployments.first.mapped_task_name
                    assert_equal deployment_m,
                                 deployments.first.configured_deployment.model
                end

                it 'stops at the first level with a matching deployment' do
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m.deployed_as('child'), as: 'child'
                    cmp = cmp_m.to_instance_requirements
                               .use_deployment(@task_m => 'test', on: 'stubs')
                               .instanciate(plan)

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp.child_child)
                    assert_equal 1, deployments.size
                    assert_equal 'child', deployments.first.mapped_task_name
                    assert_equal deployment_m,
                                 deployments.first.configured_deployment.model
                end

                it 'resolves multiple branches if the hierarchy graph forks' do
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m, as: 'child'

                    cmp0 = cmp_m.to_instance_requirements
                                .use_deployment(@task_m => 'test0', on: 'stubs')
                                .instanciate(plan)
                    cmp1 = cmp_m.to_instance_requirements
                                .use_deployment(@task_m => 'test1', on: 'stubs')
                                .instanciate(plan)
                    cmp1.remove_child(cmp1.child_child)
                    cmp1.depends_on cmp0.child_child, role: 'child'

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp0.child_child)
                    assert_equal 2, deployments.size
                    assert_equal %w[test0 test1], deployments.map(&:mapped_task_name)
                    assert_equal([deployment_m, deployment_m],
                                 deployments.map { |d| d.configured_deployment.model })
                end

                it 'reports a given deployment only once' do
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m, as: 'child'

                    cmp0 = cmp_m.to_instance_requirements
                                .use_deployment(@task_m => 'test0', on: 'stubs')
                                .instanciate(plan)
                    cmp1 = cmp_m.to_instance_requirements
                                .use_deployment(@task_m => 'test0', on: 'stubs')
                                .instanciate(plan)
                    cmp1.remove_child(cmp1.child_child)
                    cmp1.depends_on cmp0.child_child, role: 'child'

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp0.child_child)
                    assert_equal %w[test0], deployments.map(&:mapped_task_name)
                    assert_equal([deployment_m],
                                 deployments.map { |d| d.configured_deployment.model })
                end

                it 'falls back on the default deployment group if there are no suitable definitions in the hierarchy' do
                    @deployer.default_deployment_group
                             .use_deployment(@task_m => 'test', on: 'stubs')

                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m, as: 'child'
                    cmp0 = cmp_m.to_instance_requirements.instanciate(plan)
                    cmp1 = cmp_m.to_instance_requirements.instanciate(plan)
                    cmp1.remove_child(cmp1.child_child)
                    cmp1.depends_on cmp0.child_child, role: 'child'

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp0.child_child)
                    assert_equal %w[test], deployments.map(&:mapped_task_name)
                    assert_equal([deployment_m],
                                 deployments.map { |d| d.configured_deployment.model })
                end

                it 'returns an empty set if there is nothing suitable' do
                    cmp_m = Syskit::Composition.new_submodel
                    cmp_m.add @task_m, as: 'child'
                    cmp0 = cmp_m.to_instance_requirements.instanciate(plan)
                    cmp1 = cmp_m.to_instance_requirements.instanciate(plan)
                    cmp1.remove_child(cmp1.child_child)
                    cmp1.depends_on cmp0.child_child, role: 'child'

                    deployments = @deployer
                                  .find_all_suitable_deployments_for(cmp0.child_child)
                    assert_equal Set.new, deployments
                end
            end

            describe '#find_suitable_deployment_for' do
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

                it 'returns the possible deployment if it is unique' do
                    flexmock(deployer).should_receive(:find_all_suitable_deployments_for)
                                      .with(task)
                                      .and_return([deployment = flexmock])
                    assert_equal deployment,
                                 deployer.find_suitable_deployment_for(task)
                end
                it 'disambiguates tasks that have more than one possible deployments' do
                    flexmock(deployer).should_receive(:find_all_suitable_deployments_for)
                                      .with(task)
                                      .and_return(candidates = [flexmock, deployment1 = flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity)
                                      .with(candidates, task)
                                      .and_return(deployment1)
                    assert_equal deployment1,
                                 deployer.find_suitable_deployment_for(task)
                end
                it 'returns nil if the disambiguation failed' do
                    flexmock(deployer).should_receive(:find_all_suitable_deployments_for)
                                      .with(task)
                                      .and_return([flexmock, flexmock])
                    flexmock(deployer).should_receive(:resolve_deployment_ambiguity)
                                      .and_return(nil)
                    assert_nil deployer.find_suitable_deployment_for(task)
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
                    assert_raises(MissingDeployments) do
                        deployer.validate_deployed_network
                    end
                end
            end
        end
    end
end
