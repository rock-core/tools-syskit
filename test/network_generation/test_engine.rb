require 'syskit'
require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::NetworkGeneration::Engine do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
        stub_roby_deployment_model(simple_component_model)
        plan.engine.scheduler = nil
    end

    def work_plan; orocos_engine.work_plan end

    describe "#instanciate" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :requirements
        before do
            plan.add_mission(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            @requirements = planning_task.requirements
        end

        it "adds instanciated tasks as permanent tasks" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            orocos_engine.prepare
            orocos_engine.instanciate
            assert work_plan.permanent?(instanciated_task)
        end
        it "saves the mapping from requirement task in real_plan to instanciated task in work_plan" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new)
            orocos_engine.prepare
            orocos_engine.instanciate
            assert_equal instanciated_task, orocos_engine.required_instances[planning_task]
        end
        it "adds to the plan requirements from running InstanceRequirementsTask tasks" do
            planning_task.start!
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new).once
            orocos_engine.prepare
            orocos_engine.instanciate
            assert work_plan.include? instanciated_task
        end
        it "adds to the plan requirements from InstanceRequirementsTask tasks that successfully finished" do
            planning_task.start!
            planning_task.emit :success
            flexmock(requirements).should_receive(:instanciate).
                and_return(instanciated_task = simple_component_model.new).once
            orocos_engine.prepare
            orocos_engine.instanciate
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
            orocos_engine.prepare
            orocos_engine.instanciate
            plan.remove_object(planning_task) # for a silent teardown
        end
        it "ignores InstanceRequirementsTask tasks that are pending" do
            flexmock(requirements).should_receive(:instanciate).never
            orocos_engine.prepare
            orocos_engine.instanciate
        end
    end

    describe "#fix_toplevel_tasks" do
        attr_reader :original_task
        attr_reader :planning_task
        attr_reader :final_task
        before do
            plan.add(@original_task = simple_component_model.as_plan)
            @planning_task = original_task.planning_task
            orocos_engine.prepare
            orocos_engine.work_plan.add_permanent(@final_task = simple_component_model.new)
            orocos_engine.required_instances[original_task.planning_task] = final_task
        end

        it "leaves non-mission and non-permanent tasks as non-mission and non-permanent" do
            orocos_engine.fix_toplevel_tasks
            assert !work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks permanent as permanent" do
            plan.add_permanent(original_task)
            orocos_engine.fix_toplevel_tasks
            assert work_plan.permanent?(final_task)
            assert !work_plan.mission?(final_task)
        end
        it "marks missions as mission" do
            plan.add_mission(original_task)
            orocos_engine.fix_toplevel_tasks
            assert !work_plan.permanent?(final_task)
            assert work_plan.mission?(final_task)
        end
        it "replaces toplevel tasks by their deployed equivalent" do
            service = original_task.as_service
            orocos_engine.fix_toplevel_tasks
            orocos_engine.work_plan.commit_transaction
            assert_same service.task, final_task
            assert_same final_task.planning_task, planning_task
        end
    end

    describe "synthetic tests" do
        def deploy_task(requirements)
            plan.add(original_task = requirements.as_plan)
            task = original_task.as_service
            task.planning_task.start!
            orocos_engine.resolve
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
            assert !new_deployed.child_child.allow_automatic_setup?
            assert_equal([original, deployed, deployed.child_from_role('child'), new_original].to_set, plan.static_garbage_collect.to_set)
            assert new_deployed.child_child.allow_automatic_setup?
        end

        it "reconfigures a toplevel task if its configuration changed" do
            task_model = Syskit::TaskContext.new_submodel
            deployment = stub_roby_deployment_model(task_model, 'task')

            deployed_task, original_task, planning_task = deploy_task(task_model)
            plan.remove_object(planning_task)
            deployed_reconf, original_reconf, _ = deploy_task(task_model.with_conf('non_default'))
            plan.add_mission(deployed_reconf)

            assert_equal([deployed_task, original_task, original_reconf].to_set, plan.static_garbage_collect.to_set)
            assert(['non_default'], deployed_reconf.conf)
        end

        it "reconfigures tasks using allow_automatic_setup" do
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

            assert !new_child.allow_automatic_setup?
            plan.remove_object(child)
            assert new_child.allow_automatic_setup?
        end

        it "does not change anything if asked to deploy the same composition twice" do
            begin
                task_model = Syskit::TaskContext.new_submodel
                composition_model = Syskit::Composition.new_submodel do
                    add task_model, :as => 'child'
                end
                deployment = stub_roby_deployment_model(task_model, 'task')

                # IMPORTANT: using add_mission here makes the task "special", as it is
                # protected from e.g. garbage collection. The test should pass without
                # it
                deploy_task(composition_model.use('child' => task_model))
                assert_equal 5, plan.known_tasks.size
                current_tasks = plan.known_tasks.dup

                plan_copy, mappings = plan.deep_copy

                orocos_engine.resolve
                assert plan.same_plan?(plan_copy, mappings)
            ensure
                plan_copy.clear if plan_copy
            end
        end
    end
end

