require 'syskit/test/self'

describe Syskit::RobyApp::Configuration do
    describe "#use_deployment" do
        attr_reader :task_m, :conf
        before do
            @task_m = Syskit::TaskContext.new_submodel(name: 'test::Task')
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            conf.register_process_server('localhost', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
            conf.register_process_server('test', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        def stub_deployment(name)
            task_m = @task_m
            Syskit::Deployment.new_submodel(name: name) do
                task('task', task_m.orogen_model)
            end
        end

        it "accepts a task model-to-name mapping" do
            deployment_m = stub_deployment 'test'
            default_deployment_name = OroGen::Spec::Project.
                default_deployment_name('test::Task')
            flexmock(@conf.app.default_loader).
                should_receive(:deployment_model_from_name).
                with(default_deployment_name).
                and_return(deployment_m.orogen_model)
            configured_deployments = conf.use_deployment task_m => 'task'
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            assert_equal task_m.orogen_model, configured_d.model.tasks.first.task_model
        end
    end

    describe "#use_ruby_tasks" do
        before do
            @task_m = Syskit::RubyTaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server('ruby_tasks',
                Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        it "defines a deployment for a given ruby task context model" do
            configured_deployments = @conf.use_ruby_tasks @task_m => 'task'
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            assert_equal @task_m.deployment_model, configured_d.model
        end
    end

    describe "#use_unmanaged_task" do
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server('unmanaged_tasks',
                Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end
        it "defines a configured deployment from a task model and name" do
            configured_deployments = @conf.use_unmanaged_task @task_m => 'name'
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            deployed_task = configured_d.each_orogen_deployed_task_context_model.
                first
            assert_equal 'name', deployed_task.name
            assert_equal @task_m.orogen_model, deployed_task.task_model
        end
    end
end
