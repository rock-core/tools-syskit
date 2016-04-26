require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceRequirementsTask do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :cmp_m

    before do
        create_simple_composition_model
        plan.execution_engine.scheduler.enabled = false
        @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(plan.execution_engine)
        @cmp_m = Syskit::Composition.new_submodel
    end

    it "triggers a network resolution when started" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        task.planning_task.start!
        assert plan.syskit_current_resolution
    end

    it "finishes with failure if the network resolution failed" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        flexmock(Syskit::NetworkGeneration::Engine).
            new_instances.should_receive(:resolve_system_network).and_raise(ArgumentError)
        Roby.logger.level = Logger::FATAL
        resolution = nil
        assert_raises(Roby::PlanningFailedError) do
            assert_event_emission(req_task.failed_event) do
                req_task.start!
                resolution = plan.syskit_current_resolution
            end
        end
        assert resolution.transaction_finalized?
        assert !resolution.transaction_committed?
        assert req_task.failed?
    end

    it "finishes with failure if the network application failed" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        flexmock(Syskit::NetworkGeneration::Engine).
            new_instances.should_receive(:apply_system_network_to_plan).and_raise(ArgumentError)
        Roby.logger.level = Logger::FATAL
        resolution = nil
        assert_raises(Roby::PlanningFailedError) do
            assert_event_emission(req_task.failed_event) do
                req_task.start!
                resolution = plan.syskit_current_resolution
            end
        end
        assert resolution.transaction_finalized?
        assert !resolution.transaction_committed?
        assert req_task.failed?
    end

    it "finishes successfully if the network resolution succeeds" do
        cmp_m = Syskit::Composition.new_submodel
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        resolution = nil
        assert_event_emission(req_task.success_event) do
            req_task.start!
            resolution = plan.syskit_current_resolution
        end
        assert resolution.transaction_finalized?
        assert resolution.transaction_committed?
        assert req_task.success?
    end

    describe ".subplan" do
        it "creates an abstract task of the receiver's model as placeholder" do
            c = Syskit::Component.new_submodel
            plan.add(task = Syskit::InstanceRequirementsTask.subplan(c))
            assert_kind_of c, task
            assert task.abstract?
        end

        it "creates a plan pattern in which the planning task is a InstanceRequirementsTask with the required requirements" do
            c = Syskit::Component.new_submodel
            plan.add(task = Syskit::InstanceRequirementsTask.subplan(c))
            task = task.planning_task
            assert_kind_of Syskit::InstanceRequirementsTask, task
            assert_equal c, task.requirements.model
        end
    end
end

