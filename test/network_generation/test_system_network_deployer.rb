require 'syskit/test/self'

module Syskit
    module NetworkGeneration
        describe SystemNetworkDeployer do
            subject { SystemNetworkDeployer.new(plan) }
            def merge_solver; flexmock(subject.merge_solver) end

            describe "#compute_task_context_deployment_candidates" do
                it "lists the deployments on a per-model basis" do
                    task_m_1 = TaskContext.new_submodel
                    deployment_1 = syskit_stub_deployment_model(task_m_1, 'task')
                    task_m_2 = TaskContext.new_submodel
                    deployment_2 = syskit_stub_deployment_model(task_m_2, 'other_task')

                    result = subject.compute_task_context_deployment_candidates

                    a, b, c = result[task_m_1].to_a.first
                    assert_equal ['stubs', deployment_1, 'task'], [a, b.model, c]
                    a, b, c = result[task_m_2].to_a.first
                    assert_equal ['stubs', deployment_2, 'other_task'], [a, b.model, c]
                end
            end

            describe "#resolve_deployment_ambiguity" do
                it "resolves ambiguity by orocos_name" do
                    candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
                    assert_equal candidates[1],
                        subject.resolve_deployment_ambiguity(candidates, flexmock(orocos_name: 'other_task'))
                end
                it "resolves ambiguity by deployment hints if there are no name" do
                    candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [/other/])
                    assert_equal candidates[1],
                        subject.resolve_deployment_ambiguity(candidates, task)
                end
                it "returns nil if there are neither an orocos name nor hints" do
                    candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [], model: nil)
                    assert !subject.resolve_deployment_ambiguity(candidates, task)
                end
                it "returns nil if the hints don't allow to resolve the ambiguity" do
                    candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
                    task = flexmock(orocos_name: nil, deployment_hints: [/^other/, /^task/], model: nil)
                    assert !subject.resolve_deployment_ambiguity(candidates, task)
                end
            end

            describe "#select_deployments" do
                attr_reader :deployment_models, :deployments, :task_models
                before do
                    @deployment_models = [Syskit::Deployment.new_submodel, Syskit::Deployment.new_submodel]
                    @task_models = [Syskit::TaskContext.new_submodel, Syskit::TaskContext.new_submodel]
                    @deployments = Hash[
                        task_models[0] => [['machine', deployment_models[0], 'task']],
                        task_models[1] => [['other_machine', deployment_models[1], 'other_task']]
                    ]
                    deployment_models[0].orogen_model.task 'task', task_models[0].orogen_model
                    deployment_models[1].orogen_model.task 'other_task', task_models[1].orogen_model
                end

                subject do
                    deployer = SystemNetworkDeployer.new(plan)
                    deployer.task_context_deployment_candidates.merge!(deployments)
                    deployer
                end

                it "does not allocate the same task twice" do
                    plan.add(task0 = task_models[0].new)
                    plan.add(task1 = task_models[0].new)
                    all_tasks = [task0, task1]
                    selected, missing = subject.select_deployments(all_tasks)
                    assert_equal 1, missing.size
                    assert [task0, task1].include?(missing.first)
                end
                it "does not resolve ambiguities by considering already allocated tasks" do
                    plan.add(task0 = task_models[0].new(orocos_name: 'task'))
                    plan.add(task1 = task_models[0].new)
                    all_tasks = [task0, task1]
                    selected, missing = subject.select_deployments(all_tasks)
                    assert_equal [task1], missing.to_a
                end
            end

            describe "#deploy" do
                attr_reader :deployment_models, :deployments, :task_models
                before do
                    @deployment_models = [Syskit::Deployment.new_submodel, Syskit::Deployment.new_submodel]
                    @task_models = [Syskit::TaskContext.new_submodel, Syskit::TaskContext.new_submodel]
                    @deployments = Hash[
                        task_models[0] => [['machine', deployment_models[0], 'task']],
                        task_models[1] => [['other_machine', deployment_models[1], 'other_task']]
                    ]
                    deployment_models[0].orogen_model.task 'task', task_models[0].orogen_model
                    deployment_models[1].orogen_model.task 'other_task', task_models[1].orogen_model
                end

                subject do
                    deployer = SystemNetworkDeployer.new(plan)
                    deployer.task_context_deployment_candidates.merge!(deployments)
                    deployer
                end

                it "applies the known deployments before returning the missing ones" do
                    deployer = flexmock(subject)
                    deployer.should_receive(:select_deployments).
                        and_return([selected = flexmock(:empty? => false), missing = flexmock(:empty? => false)])
                    deployer.should_receive(:apply_selected_deployments).
                        with(selected).once
                    assert_equal missing, deployer.deploy
                end

                it "creates the necessary deployment task and uses #task to get the deployed task context" do
                    plan.add(task = task_models[0].new)
                    # Create on the right host
                    flexmock(deployment_models[0]).should_receive(:new).once.
                        with(on: 'machine').
                        and_return(deployment_task = flexmock(Roby::Task.new))
                    # Add it to the work plan
                    flexmock(plan).should_receive(:add).once.with(deployment_task).ordered.pass_thru
                    # Create the task
                    deployment_task.should_receive(:task).with('task').and_return(deployed_task = flexmock).ordered
                    # And finally replace the task with the deployed task
                    merge_solver.should_receive(:apply_merge_group).once.with(task => deployed_task)
                    subject.deploy(validate: false)
                end
                it "instanciates the same deployment only once on the same machine" do
                    plan.add(task0 = task_models[0].new(orocos_name: 'task'))
                    plan.add(task1 = task_models[0].new(orocos_name: 'other_task'))

                    subject.task_context_deployment_candidates.merge!(
                        task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
                    )
                    flexmock(plan).should_receive(:add)

                    # Create on the right host
                    flexmock(deployment_models[0]).should_receive(:new).once.
                        with(on: 'machine').
                        and_return(deployment_task = flexmock(Roby::Task.new))
                    deployment_task.should_receive(:task).with('task').once.and_return(task = flexmock)
                    deployment_task.should_receive(:task).with('other_task').once.and_return(other_task = flexmock)
                    merge_solver.should_receive(:apply_merge_group).once.with(task0 => task)
                    merge_solver.should_receive(:apply_merge_group).once.with(task1 => other_task)
                    # And finally replace the task with the deployed task
                    assert_equal Set.new, subject.deploy(validate: false)

                end
                it "instanciates the same deployment twice if on two different machines" do
                    plan.add(task0 = task_models[0].new(orocos_name: 'task'))
                    plan.add(task1 = task_models[0].new(orocos_name: 'other_task'))

                    subject.task_context_deployment_candidates.merge!(
                        task_models[0] => [
                            ['machine', deployment_models[0], 'task'],
                            ['other_machine', deployment_models[0], 'other_task']
                        ]
                    )
                    flexmock(plan).should_receive(:add)

                    flexmock(Roby::Queries::Query).new_instances.should_receive(:to_a).and_return([task0, task1])
                    # Create on the right host
                    flexmock(deployment_models[0]).should_receive(:new).once.
                        with(on: 'machine').
                        and_return(deployment_task0 = flexmock(Roby::Task.new))
                    flexmock(deployment_models[0]).should_receive(:new).once.
                        with(on: 'other_machine').
                        and_return(deployment_task1 = flexmock(Roby::Task.new))
                    deployment_task0.should_receive(:task).with('task').once.and_return(task = flexmock)
                    deployment_task1.should_receive(:task).with('other_task').once.and_return(other_task = flexmock)
                    merge_solver.should_receive(:apply_merge_group).once.with(task0 => task)
                    merge_solver.should_receive(:apply_merge_group).once.with(task1 => other_task)
                    # And finally replace the task with the deployed task
                    assert_equal Set.new, subject.deploy(validate: false)
                end
                it "does not consider already deployed tasks" do
                    plan.add(task0 = task_models[0].new)

                    subject.task_context_deployment_candidates.merge!(
                        task_models[0] => [['machine', deployment_models[0], 'task']])
                    
                    flexmock(plan).should_receive(:add).never
                    merge_solver.should_receive(:apply_merge_group).never

                    flexmock(task0).should_receive(:execution_agent).and_return(true)
                    flexmock(deployment_models[0]).should_receive(:new).never
                    assert_equal Set.new, subject.deploy
                end
            end

        end
    end
end

