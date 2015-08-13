require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::Engine do
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
        plan.engine.scheduler.enabled = false
        @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
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
            syskit_stub_deployment_model(simple_component_model)
            syskit_engine.create_work_plan_transaction
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
                rescue Roby::PlanningFailedError
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
        it "stores the mission status of the required task in the toplevel_tasks set" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            syskit_engine.instanciate
            assert_equal [true, false], syskit_engine.toplevel_tasks[instanciated_task]
        end
        it "stores the permanent status of the required task in the toplevel_tasks set" do
            plan.add_permanent(original_task)
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            syskit_engine.instanciate
            assert_equal [true, true], syskit_engine.toplevel_tasks[instanciated_task]
        end
        it "allocates devices using the task instance requirement information" do
            dev_m = Syskit::Device.new_submodel
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add simple_task_model, as: 'test'
            simple_task_model.driver_for dev_m, as: 'device'
            device = robot.device dev_m, as: 'test'
            requirements = cmp_m.use(device)

            original_task = requirements.as_plan
            plan.add_permanent(original_task)
            original_task.planning_task.start!
            syskit_engine.instanciate
            cmp = syskit_engine.required_instances[original_task.planning_task]
            assert_equal device, cmp.test_child.device_dev
        end
        it "sets the task's fullfilled model to the instance requirement's" do
            task_m = Syskit::TaskContext.new_submodel do
                argument :arg
            end
            req = Syskit::InstanceRequirements.new([task_m]).
                with_arguments(arg: 10)
            plan.add_permanent(original = req.as_plan)
            original.planning_task.start!
            syskit_engine.instanciate
            task = syskit_engine.required_instances[original.planning_task]
            assert_equal [[task_m], Hash[arg: 10]], task.fullfilled_model
        end
        it "use the arguments as filtered by the task" do
            task_m = Syskit::TaskContext.new_submodel
            task_m.argument :arg
            task_m.class_eval do
                def arg=(value)
                    self.arguments[:arg] = value / 2
                end
            end
            req = Syskit::InstanceRequirements.new([task_m]).
                with_arguments(arg: 10)
            plan.add_permanent(original = req.as_plan)
            original.planning_task.start!
            syskit_engine.instanciate
            task = syskit_engine.required_instances[original.planning_task]
            assert_equal 5, task.arg
            assert_equal [[task_m], Hash[arg: 5]], task.fullfilled_model
        end
    end

    describe "#fix_toplevel_tasks" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :final_task
        before do
            plan.add(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            syskit_engine.create_work_plan_transaction
            syskit_engine.prepare
            syskit_engine.work_plan.add_permanent(@final_task = simple_component_model.new)
            syskit_engine.required_instances[original_task.planning_task] = final_task
            syskit_engine.add_toplevel_task(final_task, false, false)
            syskit_stub_deployment_model(simple_component_model)
        end

        it "leaves non-mission and non-permanent tasks as non-mission and non-permanent" do
            syskit_engine.fix_toplevel_tasks
            assert !work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks permanent as permanent" do
            syskit_engine.add_toplevel_task(final_task, false, true)
            syskit_engine.fix_toplevel_tasks
            assert work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks missions as mission" do
            syskit_engine.add_toplevel_task(final_task, true, false)
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

            assert Roby::EventStructure::SyskitConfigurationPrecedence.linked?(task.stop_event, new_task.start_event)
        end

        it "does not reconfigure not-setup tasks" do
            task = syskit_stub_and_deploy("Task", as: 'task') { input_port('in', '/double').static }
            syskit_engine.reconfigure_tasks_on_static_port_modification([task])
            tasks = work_plan.find_local_tasks(Syskit::TaskContext).
                with_arguments(orocos_name: task.orocos_name).to_a
            assert_equal [task], tasks
        end
    end

    describe "#compute_deployed_models" do
        it "should register all fullfilled models for deployed tasks" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            parent_model = Syskit::TaskContext.new_submodel(name: 'ParentTask')
            task_model = parent_model.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            provided_models = [service_model, parent_model, task_model].to_value_set
            syskit_stub_deployment_model(task_model, 'task')
            
            assert_equal provided_models.to_value_set, syskit_engine.compute_deployed_models.to_value_set
        end
        it "should be able to discover compositions that are enabled because of deployed tasks" do
            service_model = Syskit::DataService.new_submodel(name: 'Srv')
            task_model = Syskit::TaskContext.new_submodel(name: 'Task') { provides service_model, as: 'srv' }
            composition_model = Syskit::Composition.new_submodel do
                add service_model, as: 'child'
            end
            syskit_stub_deployment_model(task_model, 'task')
            assert_equal [service_model, task_model, composition_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
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
            assert_equal [service_model, task_model, composition_model, composition_service_model, next_composition_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
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
            assert_equal [service_model, task_model].to_value_set,
                syskit_engine.compute_deployed_models.to_value_set
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
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments).by_default
            syskit_engine.prepare(validate_deployed_network: false, validate_final_network: false)
        end

        it "creates the necessary deployment task and uses #task to get the deployed task context" do
            syskit_engine.work_plan.add(task = task_models[0].new)
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'machine').
                and_return(deployment_task = flexmock(Roby::Task.new))
            # Add it to the work plan
            flexmock(syskit_engine.work_plan).should_receive(:add_task).once.with(deployment_task).ordered
            # Create the task
            deployment_task.should_receive(:task).with('task').and_return(deployed_task = flexmock).ordered
            # And finally replace the task with the deployed task
            flexmock(syskit_engine.merge_solver).should_receive(:merge).once.with(task, deployed_task)
            syskit_engine.update_deployed_models
            syskit_engine.deploy_system_network
        end
        it "instanciates the same deployment only once on the same machine" do
            syskit_engine.work_plan.add(task0 = task_models[0].new(orocos_name: 'task'))
            syskit_engine.work_plan.add(task1 = task_models[0].new(orocos_name: 'other_task'))

            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'machine').
                and_return(deployment_task = flexmock(Roby::Task.new))
            deployment_task.should_receive(:task).with('task').once
            deployment_task.should_receive(:task).with('other_task').once
            # And finally replace the task with the deployed task
            syskit_engine.update_deployed_models
            assert_equal [], syskit_engine.deploy_system_network
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
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            flexmock(Roby::Queries::Query).new_instances.should_receive(:to_a).and_return([task0, task1])
            # Create on the right host
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'machine').
                and_return(deployment_task0 = flexmock(Roby::Task.new))
            flexmock(deployment_models[0]).should_receive(:new).once.
                with(on: 'other_machine').
                and_return(deployment_task1 = flexmock(Roby::Task.new))
            deployment_task0.should_receive(:task).with('task').once
            deployment_task1.should_receive(:task).with('other_task').once
            # And finally replace the task with the deployed task
            syskit_engine.update_deployed_models
            assert_equal [], syskit_engine.deploy_system_network
        end
        it "does not allocate the same task twice" do
            syskit_engine.work_plan.add(task0 = task_models[0].new)
            syskit_engine.work_plan.add(task1 = task_models[0].new)

            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            flexmock(deployment_models[0]).should_receive(:new).once.
                and_return(deployment_task0 = flexmock(Roby::Task.new))
            deployment_task0.should_receive(:task).with('task').once
            syskit_engine.update_deployed_models

            missing = syskit_engine.deploy_system_network.to_a
            # We don't control which of the two tasks got deployed
            assert_equal 1, missing.size
            assert [task0, task1].include?(missing.first)
        end
        it "does not resolve ambiguities by considering already allocated tasks" do
            syskit_engine.work_plan.add(task0 = task_models[0].new(orocos_name: 'task'))
            syskit_engine.work_plan.add(task1 = task_models[0].new)

            deployments = Hash[
                task_models[0] => [['machine', deployment_models[0], 'task'], ['machine', deployment_models[0], 'other_task']]
            ]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add)
            flexmock(syskit_engine.merge_solver).should_receive(:merge)

            flexmock(deployment_models[0]).should_receive(:new).once.
                and_return(deployment_task0 = flexmock(Roby::Task.new))
            deployment_task0.should_receive(:task).with('task').once
            syskit_engine.update_deployed_models
            assert_equal [task1], syskit_engine.deploy_system_network.to_a
        end
        it "does not consider already deployed tasks" do
            syskit_engine.work_plan.add(task0 = task_models[0].new)

            deployments = Hash[task_models[0] => [['machine', deployment_models[0], 'task']]]
            flexmock(syskit_engine).should_receive(:compute_task_context_deployment_candidates).
                and_return(deployments)
            flexmock(syskit_engine.work_plan).should_receive(:add).never
            flexmock(syskit_engine.merge_solver).should_receive(:merge).never

            flexmock(task0).should_receive(:execution_agent).and_return(true)
            flexmock(deployment_models[0]).should_receive(:new).never
            syskit_engine.update_deployed_models
            assert_equal [], syskit_engine.deploy_system_network
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
        def deploy_task(requirements)
            plan.add_permanent(original_task = requirements.as_plan)
            task = original_task.as_service
            task.planning_task.start!
            syskit_engine.resolve
            task.planning_task.emit :success
            return task.task, original_task, task.planning_task
        ensure
            plan.unmark_permanent(original_task)
        end

        it "deploys a mission as mission" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = syskit_stub_deployment_model(task_model, 'task')
            plan.add_mission(original_task = task_model.as_plan)
            deployed, original_task, planning_task = deploy_task(original_task)
            refute_same deployed, original_task
            assert plan.mission?(deployed)
        end

        it "deploys a permanent task as permanent" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = syskit_stub_deployment_model(task_model, 'task')
            plan.add_permanent(original_task = task_model.as_plan)
            deployed, original_task, planning_task = deploy_task(original_task)
            refute_same deployed, original_task
            assert plan.permanent?(deployed)
        end

        it "reconfigures a child task if needed" do
            task_model = Syskit::TaskContext.new_submodel
            composition_model = Syskit::Composition.new_submodel do
                add task_model, as: 'child'
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')

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
            deployment = syskit_stub_deployment_model(task_model, 'task')

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
                add task_model, as: 'child'
            end
            deployment = syskit_stub_deployment_model(task_model, 'task')

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
                    add task_model, as: 'child'
                end
                deployment = syskit_stub_deployment_model(task_model, 'task')

                deploy_task(composition_model.use('child' => task_model))
                plan.engine.garbage_collect
                plan_copy, mappings = plan.deep_copy

                syskit_engine.resolve
                plan.engine.garbage_collect
                assert plan.same_plan?(plan_copy, mappings)
            ensure
                plan_copy.clear if plan_copy
            end
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
            cmp, _ = deploy_task(composition_model)
            assert_equal Hash[['out', 'out'] => Hash.new], cmp.child_child[cmp, Syskit::Flows::DataFlow]
        end
    end

    describe "#allocate_devices" do
        attr_reader :dev_m, :task_m, :cmp_m, :device, :cmp, :task
        before do
            dev_m = @dev_m = Syskit::Device.new_submodel name: 'Driver'
            @task_m = Syskit::TaskContext.new_submodel(name: 'Task') { driver_for dev_m, as: 'driver' }
            @cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: 'test'
            @device = robot.device dev_m, as: 'd'
            @cmp = cmp_m.instanciate(plan)
            @task = cmp.test_child
        end
        it "sets missing devices from its selections" do
            engine = Syskit::NetworkGeneration::Engine.new(Roby::Plan.new)
            task.requirements.push_dependency_injection(Syskit::DependencyInjection.new(dev_m => device))
            engine.allocate_devices(task)
            assert_equal device, task.find_device_attached_to(task.driver_srv)
        end
        it "sets missing devices from the selections in its parent(s)" do
            engine = Syskit::NetworkGeneration::Engine.new(Roby::Plan.new)
            cmp.requirements.merge(cmp_m.use(dev_m => device))
            engine.allocate_devices(task)
            assert_equal device, task.find_device_attached_to(task.driver_srv)
        end
        it "does not override already set devices" do
            dev2 = robot.device dev_m, as: 'd2'
            task.arguments['driver_dev'] = dev2
            cmp.requirements.merge(cmp_m.use(dev_m => device))
            engine = Syskit::NetworkGeneration::Engine.new(Roby::Plan.new)
            engine.allocate_devices(task)
            assert_equal dev2, task.find_device_attached_to(task.driver_srv)
        end
    end
end

