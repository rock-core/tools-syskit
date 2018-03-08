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

        it "raises if the given model is a composition" do
            cmp_m = Syskit::Composition.new_submodel
            e = assert_raises(ArgumentError) do
                conf.use_deployment cmp_m => 'task'
            end
            assert_equal "only deployment and task context models can be deployed "\
                "by use_deployment, got #{cmp_m}", e.message
        end

        it "raises if the given model is a RubyTaskContext" do
            task_m = Syskit::RubyTaskContext.new_submodel
            e = assert_raises(ArgumentError) do
                conf.use_deployment task_m => 'task'
            end
            assert_equal "only deployment and task context models can be deployed "\
                "by use_deployment, got #{task_m}", e.message
        end

        it "raises if the task has no default deployment" do
            assert_raises(OroGen::DeploymentModelNotFound) do
                conf.use_deployment task_m => 'task'
            end
        end

        it "does not raise TaskNameAlreadyInUse if there is a different deployment that "\
           "provides the same orocos task name" do
            deployment1_m = stub_deployment 'deployment1'
            deployment2_m = stub_deployment 'deployment2'
            conf.use_deployment deployment1_m
            assert_raises(Syskit::TaskNameAlreadyInUse) do
                conf.use_deployment deployment2_m
            end
        end
        it "does not raise if the same deployment is configured "\
           "with a different mapping" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m => 'prefix_'
        end
        it "does not raise if the same deployment is registered again" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m
        end
        it "registers the same deployment only once" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m
            assert_equal 1, conf.deployments['localhost'].size
        end
        it "should allow registering on another process server" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m, on: 'test'
            assert_equal 1, conf.deployments['test'].size
        end
        it "raises OroGen::NotFound if the deployment does not exist" do
            e = assert_raises(OroGen::NotFound) do
                conf.use_deployment "does_not_exist", on: 'test'
            end
            assert_equal "does_not_exist is neither a task model nor a deployment name", e.message
        end
        it "raises TaskNameRequired if passing a task model without giving an explicit name" do
            e = assert_raises(Syskit::TaskNameRequired) do
                conf.use_deployment @task_m, on: 'test'
            end
            assert_equal "you must provide a task name when starting a component by type, as e.g. use_deployment OroGen.xsens_imu.Task => 'imu'",
                e.message
        end
    end

    describe "#use_ruby_tasks" do
        before do
            @task_m = Syskit::RubyTaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server('ruby_tasks',
                Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        it "gives a proper error if the mappings argument is not a hash" do
            e = assert_raises(ArgumentError) do
                @conf.use_ruby_tasks @task_m
            end
            assert_equal "mappings should be given as model => name", e.message
        end

        it "warns about deprecation of multiple definitions" do
            task1_m = Syskit::RubyTaskContext.new_submodel
            flexmock(Roby).should_receive(:warn_deprecated).
                with(/defining more than one ruby/).once
            @conf.use_ruby_tasks @task_m => 'a', task1_m => 'b'
        end

        it "defines a deployment for a given ruby task context model" do
            configured_deployments = @conf.use_ruby_tasks @task_m => 'task'
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            assert_equal @task_m.deployment_model, configured_d.model
        end

        it "raises if the model is a composition" do
            cmp_m = Syskit::Composition.new_submodel
            e = assert_raises(ArgumentError) do
                @conf.use_ruby_tasks cmp_m => 'task'
            end
            assert_equal "#{cmp_m} is not a ruby task model", e.message
        end

        it "raises if the model is a plain TaskContext" do
            task_m = Syskit::TaskContext.new_submodel
            e = assert_raises(ArgumentError) do
                @conf.use_ruby_tasks task_m => 'task'
            end
            assert_equal "#{task_m} is not a ruby task model", e.message
        end
    end

    describe "#use_unmanaged_task" do
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            @conf.register_process_server('ruby_tasks',
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
        it "accepts the task argument by name " do
            configured_deployments = @conf.use_unmanaged_task @task_m => 'name'
            assert_equal 1, configured_deployments.size
            configured_d = configured_deployments.first
            deployed_task = configured_d.each_orogen_deployed_task_context_model.
                first
            assert_equal 'name', deployed_task.name
            assert_equal @task_m.orogen_model, deployed_task.task_model
        end
        it "raises if the model is a Composition" do
            cmp_m = Syskit::Composition.new_submodel
            e = assert_raises(ArgumentError) do
                @conf.use_unmanaged_task cmp_m => 'name'
            end
            assert_equal "expected a mapping from a task context model to "\
                "a name, but got #{cmp_m}", e.message
        end
        it "raises if the model is a RubyTaskContext" do
            task_m = Syskit::RubyTaskContext.new_submodel
            e = assert_raises(ArgumentError) do
                @conf.use_unmanaged_task task_m => 'name'
            end
            assert_equal "expected a mapping from a task context model to "\
                "a name, but got #{task_m}", e.message
        end
    end
end
