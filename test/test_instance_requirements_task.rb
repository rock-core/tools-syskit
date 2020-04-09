# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::InstanceRequirementsTask do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :cmp_m

    attr_reader :stub_t
    before do
        @stub_t = stub_type "/test_t"
        create_simple_composition_model
        plan.execution_engine.scheduler.enabled = false
        @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(plan.execution_engine)
        @cmp_m = Syskit::Composition.new_submodel
    end

    it "triggers a network resolution when started" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        execute { task.planning_task.start! }
        assert plan.syskit_current_resolution
    end

    def capture_syskit_current_resolution
        flexmock(plan).should_receive(:syskit_start_async_resolution)
                      .pass_thru do |ret|
            yield(plan.syskit_current_resolution)
            ret
        end
    end

    it "finishes with failure if the network resolution failed" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        resolution = nil
        capture_syskit_current_resolution { |r| resolution = r }

        flexmock(Syskit::NetworkGeneration::Engine)
            .new_instances.should_receive(:resolve_system_network)
            .and_raise(ArgumentError)

        Roby.logger.level = Logger::FATAL
        expect_execution { req_task.start! }
            .to do
                have_error_matching Roby::PlanningFailedError
                emit req_task.failed_event
            end

        assert resolution.transaction_finalized?
        assert !resolution.transaction_committed?
    end

    it "finishes with failure if the network application failed" do
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        resolution = nil
        capture_syskit_current_resolution { |r| resolution = r }

        flexmock(Syskit::NetworkGeneration::Engine)
            .new_instances.should_receive(:apply_system_network_to_plan)
            .and_raise(ArgumentError)

        Roby.logger.level = Logger::FATAL
        expect_execution { req_task.start! }
            .to do
                have_error_matching Roby::PlanningFailedError
                emit req_task.failed_event
            end

        assert resolution.transaction_finalized?
        assert !resolution.transaction_committed?
    end

    it "finishes successfully if the network resolution succeeds" do
        cmp_m = Syskit::Composition.new_submodel
        task = plan.add_permanent_task(cmp_m.as_plan)
        req_task = task.planning_task
        resolution = nil
        capture_syskit_current_resolution { |r| resolution = r }

        expect_execution { req_task.start! }
            .to { emit req_task.success_event }
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
