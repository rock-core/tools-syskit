require 'syskit'
require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::Engine do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
        plan.engine.scheduler = nil
    end

    def work_plan; syskit_engine.work_plan end

    describe "#instanciate" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :requirements
        before do
            plan.add_mission(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            @requirements = planning_task.requirements
            stub_roby_deployment_model(simple_component_model)
            syskit_engine.prepare
        end

        it "adds instanciated tasks as permanent tasks" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            syskit_engine.instanciate
            assert work_plan.permanent?(instanciated_task)
        end
        it "saves the mapping from requirement task in real_plan to instanciated task in work_plan" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            syskit_engine.instanciate
            assert_equal instanciated_task, syskit_engine.required_instances[planning_task]
        end
        it "adds to the plan requirements from running InstanceRequirementsTask tasks" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new).once
            syskit_engine.instanciate
            assert work_plan.include? instanciated_task
        end
        it "adds to the plan requirements from InstanceRequirementsTask tasks that successfully finished" do
            planning_task.start!
            planning_task.emit :success
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new).once
            syskit_engine.instanciate
            assert work_plan.include? instanciated_task
        end
        it "ignores InstanceRequirementsTask tasks that failed" do
            planning_task.start!
            
            inhibit_fatal_messages do
                begin planning_task.emit :failed
                rescue Roby::SynchronousEventProcessingMultipleErrors
                end
            end
            flexmock(requirements).should_receive(:instanciate).never
            syskit_engine.instanciate
            plan.remove_object(planning_task) # for a silent teardown
        end
        it "ignores InstanceRequirementsTask tasks that are pending" do
            flexmock(requirements).should_receive(:instanciate).never
            syskit_engine.instanciate
        end
    end

    describe "#fix_toplevel_tasks" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :final_task
        before do
            plan.add(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            syskit_engine.prepare
            syskit_engine.work_plan.add_permanent(@final_task = simple_component_model.new)
            syskit_engine.required_instances[original_task.planning_task] = final_task
            stub_roby_deployment_model(simple_component_model)
        end

        it "leaves non-mission and non-permanent tasks as non-mission and non-permanent" do
            syskit_engine.fix_toplevel_tasks
            assert !work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks permanent as permanent" do
            plan.add_permanent(original_task)
            syskit_engine.fix_toplevel_tasks
            assert work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks missions as mission" do
            plan.add_mission(original_task)
            syskit_engine.fix_toplevel_tasks
            assert !work_plan.permanent?(final_task)
            assert work_plan.mission?(final_task)
        end
        it "replaces toplevel tasks by their deployed equivalent" do
            service = original_task.as_service
            syskit_engine.fix_toplevel_tasks
            syskit_engine.work_plan.commit_transaction
            assert_same service.task, final_task
            assert_same final_task.planning_task, planning_task
        end
    end

    describe "#compute_deployed_models" do
        it "should register all fullfilled models for deployed tasks" do
            service_model = Syskit::DataService.new_submodel(:name => 'Srv')
            parent_model = Syskit::TaskContext.new_submodel(:name => 'ParentTask')
            task_model = parent_model.new_submodel(:name => 'Task') { provides service_model, :as => 'srv' }
            provided_models = [service_model, parent_model, task_model].to_value_set
            stub_roby_deployment_model(task_model, 'task')
            
            assert_equal provided_models.to_value_set, syskit_engine.compute_deployed_models.to_value_set
        end
        it "should be able to discover compositions that are enabled because of deployed tasks" do
            service_model = Syskit::DataService.new_submodel(:name => 'Srv')
            task_model = Syskit::TaskContext.new_submodel(:name => 'Task') { provides service_model, :as => 'srv' }
            composition_model = Syskit::Composition.new_submodel do
                add service_model, :as => 'child'
            end
            stub_roby_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model, composition_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
        end
        it "should be able to discover compositions that are enabled because of other compositions" do
            service_model = Syskit::DataService.new_submodel(:name => 'Srv')
            task_model = Syskit::TaskContext.new_submodel(:name => 'Task') { provides service_model, :as => 'srv' }
            composition_service_model = Syskit::DataService.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add service_model, :as => 'child'
                provides composition_service_model, :as => 'srv'
            end
            next_composition_model = Syskit::Composition.new_submodel do
                add composition_service_model, :as => 'child'
            end
            stub_roby_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model, composition_model, composition_service_model, next_composition_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
        end
        it "should add a composition only if all its children are available" do
            service_model = Syskit::DataService.new_submodel(:name => 'Srv')
            task_model = Syskit::TaskContext.new_submodel(:name => 'Task') { provides service_model, :as => 'srv' }
            composition_service_model = Syskit::DataService.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add service_model, :as => 'child'
                add composition_service_model, :as => 'other_child'
            end
            stub_roby_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
        end
    end

    describe "#compute_task_context_deployment_candidates" do
        it "lists the deployments on a per-model basis" do
            task_model = Syskit::TaskContext.new_submodel
            deployment_1 = stub_roby_deployment_model(task_model, 'task')
            deployment_2 = stub_roby_deployment_model(simple_component_model, 'other_task')

            result = syskit_engine.compute_task_context_deployment_candidates
            assert_equal [['localhost', deployment_1, 'task']], result[task_model].to_a
            assert_equal [['localhost', deployment_2, 'other_task']], result[simple_component_model].to_a
        end
    end

    describe "#resolve_deployment_ambiguity" do
        it "resolves ambiguity by orocos_name" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            assert_equal candidates[1],
                syskit_engine.resolve_deployment_ambiguity(candidates, flexmock(:orocos_name => 'other_task'))
        end
        it "resolves ambiguity by deployment hints if there are no name" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            requirements = flexmock(:deployment_hints => [/other/])
            task = flexmock(:orocos_name => nil, :requirements => requirements)
            assert_equal candidates[1],
                syskit_engine.resolve_deployment_ambiguity(candidates, task)
        end
        it "returns nil if there are neither an orocos name nor hints" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            requirements = flexmock(:deployment_hints => [])
            task = flexmock(:orocos_name => nil, :requirements => requirements)
            assert !syskit_engine.resolve_deployment_ambiguity(candidates, task)
        end
        it "returns nil if the hints don't allow to resolve the ambiguity" do
            candidates = [['localhost', Object.new, 'task'], ['other_machine', Object.new, 'other_task']]
            requirements = flexmock(:deployment_hints => [/^other/, /^task/])
            task = flexmock(:orocos_name => nil, :requirements => requirements)
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
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments).by_default
            syskit_engine.prepare(:validate_network => false)
            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).
                with(Syskit::Deployment).and_return([])
        end

        it "creates the necessary deployment task and uses #task to get the deployed task context" do
            task = task_models[0].new
            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).and_return([task])
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(:on => 'machine').
                and_return(deployment_task = flexmock)
            # Add it to the work plan
            flexmock(syskit_engine.work_plan).should_receive(:add).once.with(deployment_task).ordered
            # Create the task
            deployment_task.should_receive(:task).with('task').and_return(deployed_task = flexmock).ordered
            # And finally replace the task with the deployed task
            flexmock(syskit_engine.merge_solver).should_receive(:merge).once.with(task, deployed_task)
            syskit_engine.deploy_system_network
        end
        it "instanciates the same deployment only once on the same machine" do
            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            task0 = task_models[0].new(:orocos_name => 'task')
            task1 = task_models[0].new(:orocos_name => 'other_task')

            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).and_return([task0, task1])
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(:on => 'machine').
                and_return(deployment_task = flexmock)
            deployment_task.should_receive(:task).with('task').once
            deployment_task.should_receive(:task).with('other_task').once
            # And finally replace the task with the deployed task
            assert_equal [], syskit_engine.deploy_system_network
        end
        it "instanciates the same deployment twice if on two different machines" do
            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['other_machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            task0 = task_models[0].new(:orocos_name => 'task')
            task1 = task_models[0].new(:orocos_name => 'other_task')

            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).
                with(Syskit::TaskContext).and_return([task0, task1])
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(:on => 'machine').
                and_return(deployment_task0 = flexmock)
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(:on => 'other_machine').
                and_return(deployment_task1 = flexmock)
            deployment_task0.should_receive(:task).with('task').once
            deployment_task1.should_receive(:task).with('other_task').once
            # And finally replace the task with the deployed task
            assert_equal [], syskit_engine.deploy_system_network
        end
        it "does not allocate the same task twice" do
            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            task0, task1 = task_models[0].new, task_models[0].new
            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).
                with(Syskit::TaskContext).and_return([task0, task1])
            flexmock(deployment_models[0]).should_receive(:new).once.
                and_return(deployment_task0 = flexmock)
            deployment_task0.should_receive(:task).with('task').once
            assert_equal [task1], syskit_engine.deploy_system_network.to_a
        end
        it "does not resolve ambiguities by considering already allocated tasks" do
            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            task0, task1 = task_models[0].new(:orocos_name => 'task'), task_models[0].new
            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).
                with(Syskit::TaskContext).and_return([task0, task1])
            flexmock(deployment_models[0]).should_receive(:new).once.
                and_return(deployment_task0 = flexmock)
            deployment_task0.should_receive(:task).with('task').once
            assert_equal [task1], syskit_engine.deploy_system_network.to_a
        end
        it "does not consider already deployed tasks" do
            deployments = Hash[task_models[0] => [['machine', deployment_models[0], 'task']]]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add).never
            flexmock(syskit_engine.merge_solver).should_receive(:merge).never

            task0 = task_models[0].new
            flexmock(task0).should_receive(:execution_agent).and_return(true)
            flexmock(syskit_engine.work_plan).should_receive(:find_local_tasks).
                with(Syskit::TaskContext).and_return([task0])
            flexmock(deployment_models[0]).should_receive(:new).never
            assert_equal [], syskit_engine.deploy_system_network
        end
    end

    describe "#adapt_existing_deployment" do
        attr_reader :task_model, :deployment_model, :existing_task, :existing_deployment_task, :task, :deployment_task, :new_task
        attr_reader :create_task
        attr_reader :merge
        before do
            @task_model = Class.new(Roby::Task) { argument :orocos_name; argument :conf }
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
            flexmock(syskit_engine.merge_solver).should_receive(:merge).once.
                with(task, existing_task)
        end

        def should_create_new_task
            new_task = task_model.new
            flexmock(existing_deployment_task).should_receive(:task).once.
                with('task', any).and_return(new_task)
            flexmock(syskit_engine.merge_solver).should_receive(:merge).once.
                with(task, new_task)
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
            flexmock(existing_task).should_receive(:can_merge?).with(task).and_return(false)
            should_create_new_task
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "ignores existing deployed tasks if they are not pending or running" do
        end
        it "synchronizes the newly created task with the end of the existing one" do
            task.orocos_name = existing_task.orocos_name = 'task'
            flexmock(existing_task).should_receive(:can_merge?).with(task).and_return(false)
            new_task = should_create_new_task
            flexmock(new_task).should_receive(:should_configure_after).with(existing_task.stop_event).once
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "does not mark the task as needing reconfiguration if the configuration did not change" do
            task.orocos_name = existing_task.orocos_name = 'task'
            task.conf = existing_task.conf = []
            should_not_create_new_task
            flexmock(existing_task).should_receive(:needs_reconfiguration!).never
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
        it "marks the tasks as needing reconfiguration if the configuration changed" do
            task.orocos_name = existing_task.orocos_name = 'task'
            task.conf = []
            existing_task.conf = ['default']
            new_task = should_create_new_task
            flexmock(existing_task).should_receive(:needs_reconfiguration!).once
            syskit_engine.adapt_existing_deployment(deployment_task, existing_deployment_task)
        end
    end

    describe "synthetic tests" do
        def deploy_task(requirements)
            plan.add(original_task = requirements.as_plan)
            task = original_task.as_service
            task.planning_task.start!
            syskit_engine.resolve
            task.planning_task.emit :success
            return task.task, original_task, task.planning_task
        end

        it "reconfigures a child task if needed" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, :as => 'child'
            end
            deployment = stub_roby_deployment_model(task_model, 'task')

            deployed, original, planning_task = deploy_task(composition_model)
            # This deregisters the task from the list of requirements in the
            # syskit engine
            plan.remove_object(planning_task)

            new_deployed, new_original = deploy_task(composition_model.use('child' => task_model.with_conf('non_default')))
            plan.add_mission(new_deployed) # we use static_garbage_collect below

            assert_equal(['non_default'], new_deployed.child_child.conf)
            assert_equal [deployed.child_child.stop_event],
                new_deployed.child_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
        end

        it "reconfigures a toplevel task if its configuration changed" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = stub_roby_deployment_model(task_model, 'task')

            deployed_task, original_task, planning_task = deploy_task(task_model)
            plan.remove_object(planning_task)
            deployed_reconf, original_reconf, _ = deploy_task(task_model.with_conf('non_default'))
            plan.add_mission(deployed_reconf)

            assert_equal [deployed_task.stop_event],
                deployed_reconf.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
            assert_equal([deployed_task, original_task, original_reconf].to_set, plan.static_garbage_collect.to_set)
            assert(['non_default'], deployed_reconf.conf)
        end

        it "reconfigures tasks using the should_reconfigure_after relation" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, :as => 'child'
            end
            deployment = stub_roby_deployment_model(task_model, 'task')

            cmp, original_cmp = deploy_task(composition_model.use('child' => task_model))
            child = cmp.child_child.to_task
            child.do_not_reuse
            plan.remove_object(cmp.planning_task)

            new_cmp, original_new = deploy_task(composition_model.use('child' => task_model))
            new_child = new_cmp.child_child

            assert_equal [child.stop_event],
                new_child.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
        end

        it "does not change anything if asked to deploy the same composition twice" do
            begin
                task_model = Syskit::TaskContext.new_submodel
                composition_model = Syskit::Composition.new_submodel do
                    add task_model, :as => 'child'
                end
                deployment = stub_roby_deployment_model(task_model, 'task')

                deploy_task(composition_model.use('child' => task_model))
                pp plan.known_tasks
                plan_copy, mappings = plan.deep_copy

                syskit_engine.resolve
                pp plan.known_tasks

                pp plan.find_plan_difference(plan_copy, mappings)
                assert plan.same_plan?(plan_copy, mappings)
            ensure
                plan_copy.clear if plan_copy
            end
        end
    end
end

