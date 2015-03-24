require 'syskit/test/self'

describe Syskit::RobyApp::Configuration do
    include Syskit::Test::Self

    describe "#use_deployment" do
        attr_reader :task_m, :conf
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
            conf.register_process_server('localhost', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
            conf.register_process_server('test', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
        end

        def stub_deployment(name)
            task_m = @task_m
            Syskit::Deployment.new_submodel(:name => name) do
                task('task', task_m.orogen_model)
            end
        end

        it "should raise TaskNameAlreadyInUse if there is a different deployment that provides the same orocos task name" do
            deployment1_m = stub_deployment 'deployment1'
            deployment2_m = stub_deployment 'deployment2'
            conf.use_deployment deployment1_m
            assert_raises(Syskit::TaskNameAlreadyInUse) do
                conf.use_deployment deployment2_m
            end
        end
        it "should not raise if the same deployment is configured with a different mapping" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m => 'prefix_'
        end
        it "should not raise if the same deployment is registered again" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m
        end
        it "should register the same deployment only once" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m
            conf.use_deployment deployment1_m
            assert_equal 1, conf.deployments['localhost'].size
        end
        it "should allow registering on another process server" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment deployment1_m, :on => 'test'
            assert_equal 1, conf.deployments['test'].size
        end
    end
end


