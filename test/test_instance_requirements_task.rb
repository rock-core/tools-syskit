require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceRequirementsTask do
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
        plan.engine.scheduler.enabled = false
        @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(engine)
    end

    it "triggers a network resolution when started" do
        plan.add(task = Roby::Task.new)
        task.planned_by(req_task = Syskit::InstanceRequirementsTask.new)
        req_task.requirements = Syskit::InstanceRequirements.new([])
        flexmock(syskit_engine).should_receive(:resolve).once
        req_task.start!
    end

    it "finishes with failure if the network resolution failed" do
        plan.add(task = Roby::Task.new)
        task.planned_by(req_task = Syskit::InstanceRequirementsTask.new)
        flexmock(syskit_engine).should_receive(:resolve).and_raise(ArgumentError)
        req_task.requirements = Syskit::InstanceRequirements.new([])
        Roby.logger.level = Logger::FATAL
        assert_raises(Roby::PlanningFailedError) { req_task.start! }
        assert req_task.failed?
    end

    it "finishes successfully if the network resolution succeeds" do
        plan.add(task = Roby::Task.new)
        task.planned_by(req_task = Syskit::InstanceRequirementsTask.new)
        req_task.requirements = Syskit::InstanceRequirements.new([])
        flexmock(syskit_engine).should_receive(:resolve)
        req_task.start!
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

