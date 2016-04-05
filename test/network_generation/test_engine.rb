require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::Engine do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :syskit_engine, :merge_solver

    before do
        create_simple_composition_model
        plan.execution_engine.scheduler.enabled = false
        @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
        @merge_solver  = flexmock(syskit_engine.merge_solver)
    end

    def work_plan; syskit_engine.work_plan end

    describe "#discover_requirement_tasks_from_plan" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :requirements
        before do
            plan.add_mission_task(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            @requirements = planning_task.requirements
        end

        it "returns running InstanceRequirementsTask tasks" do
            planning_task.start!
            assert_equal [planning_task], syskit_engine.discover_requirement_tasks_from_plan(plan)
        end
        it "returns InstanceRequirementsTask tasks that successfully finished" do
            planning_task.start!
            planning_task.success_event.emit
            assert_equal [planning_task], syskit_engine.discover_requirement_tasks_from_plan(plan)
        end
        it "ignores InstanceRequirementsTask tasks that failed" do
            planning_task.start!
            
            inhibit_fatal_messages do
                begin planning_task.failed_event.emit
                rescue Roby::PlanningFailedError
                end
            end
            assert_equal [], syskit_engine.discover_requirement_tasks_from_plan(plan)
        end
        it "ignores InstanceRequirementsTask tasks that are pending" do
            assert_equal [], syskit_engine.discover_requirement_tasks_from_plan(plan)
        end
    end

    describe "#compute_system_network" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :requirements
        before do
            plan.add_mission_task(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            @requirements = planning_task.requirements
        end

        it "saves the mapping from requirement task in real_plan to instanciated task in work_plan" do
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            mapping = syskit_engine.compute_system_network([planning_task])
            assert_equal instanciated_task, mapping[planning_task]
        end
    end

    describe "#fix_toplevel_tasks" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :final_task
        attr_reader :required_instances
        before do
            plan.add(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            syskit_engine.create_work_plan_transaction
            syskit_engine.work_plan.add_permanent_task(@final_task = simple_component_model.new)
            @required_instances = Hash[original_task.planning_task => final_task]
            syskit_stub_deployment_model(simple_component_model)
        end

        it "replaces toplevel tasks by their deployed equivalent" do
            service = original_task.as_service
            syskit_engine.fix_toplevel_tasks(required_instances)
            syskit_engine.work_plan.commit_transaction
            assert_same service.task, final_task
            assert_same final_task.planning_task, planning_task
        end
    end

    describe "#reconfigure_tasks_on_static_port_modification" do
        it "reconfigures already-configured tasks whose static input ports have been modified" do
            task = syskit_stub_deploy_and_configure("Task", as: 'task') { input_port('in', '/double').static }
            flexmock(task).should_receive(:transaction_proxy?).and_return(true)
            flexmock(task).should_receive(:transaction_modifies_static_ports?).once.and_return(true)
            syskit_engine.reconfigure_tasks_on_static_port_modification([task])
            tasks = work_plan.find_local_tasks(Syskit::TaskContext).
                with_arguments(orocos_name: task.orocos_name).to_a
            assert_equal 2, tasks.size
            tasks.delete(task)
            new_task = tasks.first

            assert_child_of task.stop_event, new_task.start_event, 
                Roby::EventStructure::SyskitConfigurationPrecedence
        end

        it "does not reconfigure already-configured tasks whose static input ports have not been modified" do
            task = syskit_stub_deploy_and_configure("Task", as: 'task') { input_port('in', '/double').static }
            flexmock(task).should_receive(:transaction_proxy?).and_return(true)
            flexmock(task).should_receive(:transaction_modifies_static_ports?).once.and_return(false)
            syskit_engine.reconfigure_tasks_on_static_port_modification([task])
            tasks = work_plan.find_local_tasks(Syskit::TaskContext).
                with_arguments(orocos_name: task.orocos_name).to_a
            assert_equal [task], tasks
        end

        it "does not reconfigure not-setup tasks" do
            task = syskit_stub_and_deploy("Task", as: 'task') { input_port('in', '/double').static }
            syskit_engine.reconfigure_tasks_on_static_port_modification([task])
            tasks = work_plan.find_local_tasks(Syskit::TaskContext).
                with_arguments(orocos_name: task.orocos_name).to_a
            assert_equal [task], tasks
        end

        describe "when child of a composition" do
            it "ensures that the existing deployment will be garbage collected" do
                task_m = Syskit::TaskContext.new_submodel
                cmp_m  = Syskit::Composition.new_submodel
                cmp_m.add task_m, as: 'test'

                cmp = syskit_stub_and_deploy(cmp_m)
                original_task = cmp.test_child
                flexmock(task_m).new_instances.should_receive(:can_be_deployed_by?).
                    with(->(proxy) { proxy.__getobj__ == cmp.test_child }).and_return(false)
                new_cmp = syskit_deploy(cmp_m)

                # Should have instanciated a new composition since the children
                # differ
                refute_equal new_cmp, cmp
                # Should have of course created a new task
                refute_equal new_cmp.test_child, cmp.test_child
                # And the old tasks should be ready to garbage-collect
                assert_equal [cmp, original_task].to_set, plan.static_garbage_collect.to_set
            end
        end

        describe "when child of a task" do
            it "ensures that the existing deployment will be garbage collected" do
                child_m  = Syskit::TaskContext.new_submodel
                parent_m = Syskit::TaskContext.new_submodel
                parent_m.singleton_class.class_eval do
                    define_method(:instanciate) do |*args|
                        task = super(*args)
                        task.depends_on(child_m.instanciate(*args), role: 'test')
                        task
                    end
                end

                syskit_stub(child_m)
                parent = syskit_stub_and_deploy(parent_m)
                child  = parent.test_child

                flexmock(child_m).new_instances.should_receive(:can_be_deployed_by?).
                    with(->(proxy) { proxy.__getobj__ == child }).and_return(false)
                new_parent = syskit_deploy(parent_m)
                new_child = new_parent.test_child

                assert_equal new_parent, parent
                refute_equal new_child, child
                # And the old tasks should be ready to garbage-collect
                assert_equal [child].to_set, plan.static_garbage_collect.to_set
            end
        end
    end

    describe "#compute_deployed_models" do
        it "should register all fullfilled models for deployed tasks" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            parent_model = Syskit::TaskContext.new_submodel(name: 'ParentTask')
            task_model = parent_model.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            provided_models = [service_model, parent_model, task_model].to_set
            syskit_stub_deployment_model(task_model, 'task')
            
            assert_equal provided_models.to_set, syskit_engine.compute_deployed_models.to_set
        end
        it "should be able to discover compositions that are enabled because of deployed tasks" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            task_model = Syskit::TaskContext.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            composition_model = Syskit::Composition.new_submodel do
                add service_model, as: 'child'
            end
            syskit_stub_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model, composition_model].to_set,
                syskit_engine.compute_deployed_models.to_set
        end
        it "should be able to discover compositions that are enabled because of other compositions" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            task_model = Syskit::TaskContext.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            composition_service_model = Syskit::DataService.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add service_model, as: 'child'
                provides composition_service_model, as: 'srv'
            end
            next_composition_model = Syskit::Composition.new_submodel do
                add composition_service_model, as: 'child'
            end
            syskit_stub_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model, composition_model, composition_service_model, next_composition_model].to_set,
                syskit_engine.compute_deployed_models.to_set
        end
        it "should add a composition only if all its children are available" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            task_model = Syskit::TaskContext.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            composition_service_model = Syskit::DataService.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add service_model, as: 'child'
                add composition_service_model, as: 'other_child'
            end
            syskit_stub_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model].to_set,
                syskit_engine.compute_deployed_models.to_set
        end
    end

    describe "#compute_task_context_deployment_candidates" do
        it "lists the deployments on a per-model basis" do
            task_model = Syskit::TaskContext.new_submodel
            deployment_1 = syskit_stub_deployment_model(task_model, 'task')
            deployment_2 = syskit_stub_deployment_model(simple_component_model, 'other_task')

            result = syskit_engine.compute_task_context_deployment_candidates

            a, b, c = result[task_model].to_a.first
            assert_equal ['stubs', deployment_1, 'task'], [a, b.model, c]
            a, b, c = result[simple_component_model].to_a.first
            assert_equal ['stubs', deployment_2, 'other_task'], [a, b.model, c]
        end
    end

    describe "#resolve_deployment_ambiguity" do
        it "resolves ambiguity by orocos_name" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            assert_equal candidates[1],
                syskit_engine.resolve_deployment_ambiguity(candidates, flexmock(orocos_name: 'other_task'))
        end
        it "resolves ambiguity by deployment hints if there are no name" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            task = flexmock(orocos_name: nil, deployment_hints: [/other/])
            assert_equal candidates[1],
                syskit_engine.resolve_deployment_ambiguity(candidates, task)
        end
        it "returns nil if there are neither an orocos name nor hints" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            task = flexmock(orocos_name: nil, deployment_hints: [], model: nil)
            assert !syskit_engine.resolve_deployment_ambiguity(candidates, task)
        end
        it "returns nil if the hints don't allow to resolve the ambiguity" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            task = flexmock(orocos_name: nil, deployment_hints: [/^other/, /^task/], model: nil)
            assert !syskit_engine.resolve_deployment_ambiguity(candidates, task)
        end
    end

    describe "#deploy_system_network" do
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
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments).by_default
            syskit_engine.update_task_context_deployment_candidates
        end

        it "applies the known deployments before returning the missing ones" do
            syskit_engine = flexmock(self.syskit_engine)
            syskit_engine.should_receive(:select_deployments).
                and_return([selected = flexmock(:empty? => false), missing = flexmock(:empty? => false)])
            syskit_engine.should_receive(:apply_selected_deployments).
                with(selected).once
            assert_equal missing, syskit_engine.deploy_system_network
        end

        it "creates the necessary deployment task and uses #task to get the deployed task context" do
            syskit_engine.work_plan.add(task = task_models[0].new)
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'machine').
                and_return(deployment_task = flexmock(Roby::Task.new))
            # Add it to the work plan
            flexmock(syskit_engine.work_plan).should_receive(:add).once.with(deployment_task).ordered.pass_thru
            # Create the task
            deployment_task.should_receive(:task).with('task').and_return(deployed_task = flexmock).ordered
            # And finally replace the task with the deployed task
            merge_solver.should_receive(:apply_merge_group).once.with(task => deployed_task)
            syskit_engine.deploy_system_network(validate: false)
        end
        it "instanciates the same deployment only once on the same machine" do
            syskit_engine.work_plan.add(task0 = task_models[0].new(orocos_name: 'task'))
            syskit_engine.work_plan.add(task1 = task_models[0].new(orocos_name: 'other_task'))

            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            syskit_engine.update_task_context_deployment_candidates
            flexmock(syskit_engine.work_plan).should_receive(:add)

            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'machine').
                and_return(deployment_task = flexmock(Roby::Task.new))
            deployment_task.should_receive(:task).with('task').once.and_return(task = flexmock)
            deployment_task.should_receive(:task).with('other_task').once.and_return(other_task = flexmock)
            merge_solver.should_receive(:apply_merge_group).once.with(task0 => task)
            merge_solver.should_receive(:apply_merge_group).once.with(task1 => other_task)
            # And finally replace the task with the deployed task
            assert_equal Set.new, syskit_engine.deploy_system_network(validate: false)

        end
        it "instanciates the same deployment twice if on two different machines" do
            syskit_engine.work_plan.add(task0 = task_models[0].new(orocos_name: 'task'))
            syskit_engine.work_plan.add(task1 = task_models[0].new(orocos_name: 'other_task'))

            deployments = Hash[
                task_models[0] => [
                    ['machine', deployment_models[0], 'task'],
                    ['other_machine', deployment_models[0], 'other_task']
                ]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)

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
            assert_equal Set.new, syskit_engine.deploy_system_network(validate: false)
        end
        it "does not allocate the same task twice" do
            syskit_engine.work_plan.add(task0 = task_models[0].new)
            syskit_engine.work_plan.add(task1 = task_models[0].new)
            all_tasks = [task0, task1]
            selected, missing = syskit_engine.select_deployments(all_tasks)
            assert_equal 1, missing.size
            assert [task0, task1].include?(missing.first)
        end
        it "does not resolve ambiguities by considering already allocated tasks" do
            syskit_engine.work_plan.add(task0 = task_models[0].new(orocos_name: 'task'))
            syskit_engine.work_plan.add(task1 = task_models[0].new)
            all_tasks = [task0, task1]
            selected, missing = syskit_engine.select_deployments(all_tasks)
            assert_equal [task1], missing.to_a
        end
        it "does not consider already deployed tasks" do
            syskit_engine.work_plan.add(task0 = task_models[0].new)

            deployments = Hash[task_models[0] => [['machine', deployment_models[0], 'task']]]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add).never
            merge_solver.should_receive(:apply_merge_group).never

            flexmock(task0).should_receive(:execution_agent).and_return(true)
            flexmock(deployment_models[0]).should_receive(:new).never
            assert_equal Set.new, syskit_engine.deploy_system_network
        end
    end

    describe "#adapt_existing_deployment" do
        attr_reader :task_model, :deployment_model, :existing_task, :existing_deployment_task, :task, :deployment_task, :new_task
        attr_reader :create_task
        attr_reader :merge
        before do
            @task_model = Class.new(Syskit::Component) { argument :orocos_name; argument :conf }
            @deployment_model = Class.new(Roby::Task) { event :ready }
            @existing_task, @existing_deployment_task = task_model.new, deployment_model.new
            existing_task.executed_by existing_deployment_task
            @task, @deployment_task = task_model.new, deployment_model.new
            task.executed_by deployment_task
            syskit_engine.work_plan.add(task)
            syskit_engine.real_plan.add(existing_task)
            @existing_task = syskit_engine.work_plan[existing_task]
            @existing_deployment_task = syskit_engine.work_plan[existing_deployment_task]
        end

        def should_not_create_new_task
            flexmock(existing_deployment_task).should_receive(:task).never
            merge_solver.should_receive(:apply_merge_group).once.
                with(task => existing_task)
        end

        def should_create_new_task
            new_task = task_model.new
            flexmock(existing_deployment_task).should_receive(:task).once.
                with('task', any).and_return(new_task)
            merge_solver.should_receive(:apply_merge_group).once.
                with(task => new_task)
            flexmock(new_task).should_receive(:should_configure_after).by_default
            new_task
        end

        it "creates a new deployed task if there is not one already" do
            existing_task.orocos_name = 'other_task'
            task.orocos_name = 'task'
            should_create_new_task
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "reuses an existing deployment" do
            task.orocos_name = existing_task.orocos_name = 'task'
            should_not_create_new_task
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "creates a new deployed task if there is an existing deployment but it cannot be merged" do
            task.orocos_name = existing_task.orocos_name = 'task'
            flexmock(task).should_receive(:can_be_deployed_by?).with(existing_task).and_return(false)
            should_create_new_task
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "ignores existing deployed tasks if they are not pending or running" do
        end
        it "synchronizes the newly created task with the end of the existing one" do
            task.orocos_name = existing_task.orocos_name = 'task'
            flexmock(task).should_receive(:can_be_deployed_by?).with(existing_task).and_return(false)
            new_task = should_create_new_task
            flexmock(new_task).should_receive(:should_configure_after).with(existing_task.stop_event).once
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
    end

    describe "synthetic tests" do
        it "deploys a mission as mission" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = syskit_stub_deployment_model(task_model, 'task')
            plan.add_mission_task(original_task = task_model.as_plan)
            deployed = syskit_deploy(original_task, add_mission: false)
            assert plan.mission_task?(deployed)
        end

        it "deploys a permanent task as permanent" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = syskit_stub_deployment_model(task_model, 'task')
            plan.add_permanent_task(original_task = task_model.as_plan)
            deployed = syskit_deploy(original_task, add_mission: false)
            assert plan.permanent_task?(deployed)
        end

        it "reconfigures a child task if needed" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, as: 'child'
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')

            deployed = syskit_deploy(composition_model)
            # This deregisters the task from the list of requirements in the
            # syskit engine
            plan.remove_task(deployed.planning_task)

            new_deployed = syskit_deploy(
                composition_model.use('child' => task_model.with_conf('non_default')))

            assert_equal(['non_default'], new_deployed.child_child.conf)
            assert_equal [deployed.child_child.stop_event],
                new_deployed.child_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
        end

        it "reconfigures a toplevel task if its configuration changed" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = syskit_stub_deployment_model(task_model, 'task')

            deployed_task = syskit_deploy(task_model)
            planning_task = deployed_task.planning_task
            plan.unmark_mission_task(deployed_task)
            deployed_reconf = syskit_deploy(task_model.with_conf('non_default'))
            plan.add_mission_task(deployed_reconf)

            assert_equal [deployed_task.stop_event],
                deployed_reconf.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
            plan.useful_tasks
            assert_equal([planning_task, deployed_task].to_set, plan.static_garbage_collect.to_set)
            assert(['non_default'], deployed_reconf.conf)
        end

        it "reconfigures tasks using the should_reconfigure_after relation" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, as: 'child'
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')

            cmp, original_cmp = syskit_deploy(composition_model.use('child' => task_model))
            child = cmp.child_child.to_task
            child.do_not_reuse
            plan.remove_task(cmp.planning_task)

            new_cmp, original_new = syskit_deploy(composition_model.use('child' => task_model))
            new_child = new_cmp.child_child

            assert_equal [child.stop_event],
                new_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
        end

        it "does not change anything if asked to deploy the same composition twice" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, as: 'child'
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')

            syskit_deploy(composition_model.use('child' => task_model))
            plan.execution_engine.garbage_collect
            plan_copy, mappings = plan.deep_copy

            syskit_engine.resolve
            plan.execution_engine.garbage_collect
            diff = plan.find_plan_difference(plan_copy, mappings)
            assert !diff, "#{diff}"
        end

        it "applies connections from compositions to the final plan" do
            task_model = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end
            composition_model = Syskit::Composition.new_submodel do
                add task_model, as: 'child'
                export child_child.out_port
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')
            cmp, _ = syskit_deploy(composition_model)
            assert_equal Hash[['out', 'out'] => Hash.new], cmp.child_child[cmp, Syskit::Flows::DataFlow]
        end

        it "sets a task's fullfilled model only for the arguments that are explicitely set in the toplevel requirements" do
            task_m = Syskit::TaskContext.new_submodel
            task_m.argument :arg0
            task = syskit_stub_and_deploy(task_m.with_arguments(arg0: flexmock(evaluate_delayed_argument: 10)))
            assert_equal Hash[], task.explicit_fullfilled_model.last
        end

        it "sets a task's fullfilled model only from the toplevel requirements" do
            # This tests checks that it is possible to have a toplevel task
            # (i.e. an explicitely required task) whose configuration is let
            # loose, and then let the rest of the network "decide" the actual
            # configuration
            #
            # It catches a bug in the setting of #fullfilled_model, that was
            # moved to InstanceRequirements#instanciate but really should be in
            # Engine#instanciate as the "requirements" due to e.g. composition
            # membership is set through the relation graph.
            task_m = Syskit::TaskContext.new_submodel
            task_m.argument :arg0
            task_m.argument :arg1
            task = syskit_stub_and_deploy(task_m.with_arguments(arg0: 10))
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add(task_m, as: 'test').with_arguments(arg1: 20)
            cmp = syskit_deploy(cmp_m)
            assert_equal Hash[arg0: 10], task.explicit_fullfilled_model.last
        end

        it "synchronizes the startup of communication busses and their supported devices" do
            combus_m = Syskit::ComBus.new_submodel message_type: '/int'
            combus_driver_m = Syskit::TaskContext.new_submodel { dynamic_output_port /.*/, '/int' }
            combus_driver_m.provides combus_m, as: 'driver'

            device_m = Syskit::Device.new_submodel
            device_driver_m = Syskit::TaskContext.new_submodel { input_port 'bus_in', '/int' }
            device_driver_m.provides combus_m.client_in_srv, as: 'bus'
            device_driver_m.provides device_m, as: 'driver'

            bus = robot.com_bus combus_m, as: 'bus'
            dev = robot.device device_m, as: 'dev'
            dev.attach_to(bus, client_to_bus: false)

            syskit_stub_deployment_model(device_driver_m)
            syskit_stub_deployment_model(combus_driver_m)
            dev_driver = syskit_stub_and_deploy(dev)
            bus_driver = plan.find_tasks(combus_driver_m).with_parent(dev_driver).first
            plan.add_mission_task(dev_driver)
            syskit_start_execution_agents(bus_driver)
            syskit_start_execution_agents(dev_driver)

            bus_driver.orocos_task.create_output_port 'dev', '/int'
            flexmock(bus_driver.orocos_task, "bus").should_receive(:start).once.globally.ordered.pass_thru
            flexmock(bus_driver.orocos_task.dev, "bus.dev").should_receive(:connect_to).once.globally.ordered.pass_thru
            flexmock(dev_driver.orocos_task, "dev").should_receive(:configure).once.globally.ordered.pass_thru
            plan.execution_engine.scheduler.enabled = true
            assert_event_emission bus_driver.start_event
            assert_event_emission dev_driver.start_event
        end

        describe "merging compositions" do
            it "does not merge compositions with an already deployed one that differs only by the underlying task's service" do
                plan = Roby::Plan.new
                srv_m = Syskit::DataService.new_submodel do
                    output_port 'out', '/double'
                end
                task_m = Syskit::TaskContext.new_submodel do
                    output_port 'out1', '/double'
                    output_port 'out2', '/double'
                end
                task_m.provides srv_m, 'out' => 'out1', as: 'out1'
                task_m.provides srv_m, 'out' => 'out2', as: 'out2'
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add srv_m, as: 'test'
                cmp_m.export cmp_m.test_child.out_port

                syskit_stub_deployment_model(task_m, 'deployed-task')
                cmp1 = syskit_deploy(cmp_m.use(task_m.out1_srv))
                cmp2 = syskit_deploy(cmp_m.use(task_m.out2_srv))
                refute_same cmp1, cmp2
            end

            it "does merge compositions regardless of the existence of an externally added dependency relation" do
                srv_m = Syskit::DataService.new_submodel do
                    output_port 'out', '/double'
                end
                task_m = Syskit::TaskContext.new_submodel do
                    output_port 'out1', '/double'
                    output_port 'out2', '/double'
                end
                task_m.provides srv_m, 'out' => 'out1', as: 'out1'
                task_m.provides srv_m, 'out' => 'out2', as: 'out2'
                cmp_m = Syskit::Composition.new_submodel
                cmp_m.add srv_m, as: 'test'
                cmp_m.export cmp_m.test_child.out_port

                syskit_stub_deployment_model(task_m, 'deployed-task')
                cmp1 = syskit_deploy(cmp_m.use(task_m.out1_srv))
                cmp2 = cmp_m.use(task_m.out2_srv).as_plan
                cmp1.depends_on cmp2
                cmp2_srv = cmp2.as_service
                cmp2.planning_task.start!
                syskit_deploy
                assert_equal Set[cmp1, cmp2, cmp2_srv.task], plan.find_tasks(cmp_m).to_set
            end
        end
    end
end

