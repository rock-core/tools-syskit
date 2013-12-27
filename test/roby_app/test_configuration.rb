require 'syskit/test/self'

describe Syskit::RobyApp::Configuration do
    include Syskit::Test::Self

    describe "#use_deployment" do
        attr_reader :task_m, :conf
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @conf = Syskit::RobyApp::Configuration.new(Roby.app)
        end

        def stub_deployment(name)
            task_m = @task_m
            deployment_m = Syskit::Deployment.new_submodel do
                task 'task', task_m.orogen_model
            end
            flexmock(Syskit::Deployment).should_receive(:find_model_from_orogen_name).
                with(name).and_return(deployment_m)
            Orocos.available_deployments[name] = true
            flexmock(Orocos).should_receive(:deployment_model_from_name).
                with(name).and_return(deployment_m.orogen_model)
            deployment_m
        end

        it "should raise TaskNameAlreadyInUse if there is a different deployment that provides the same orocos task name" do
            deployment1_m = stub_deployment 'deployment1'
            deployment2_m = stub_deployment 'deployment2'
            conf.use_deployment 'deployment1'
            assert_raises(Syskit::TaskNameAlreadyInUse) do
                conf.use_deployment 'deployment2'
            end
        end
        it "should not raise if the same deployment is configured with a different mapping" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment 'deployment1'
            conf.use_deployment 'deployment1' => 'prefix_'
        end
        it "should not raise if the same deployment is registered again" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment 'deployment1'
            conf.use_deployment 'deployment1'
        end
        it "should register the same deployment only once" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment 'deployment1'
            conf.use_deployment 'deployment1'
            assert_equal 1, conf.deployments['localhost'].size
        end
        it "should allow registering on another process server" do
            deployment1_m = stub_deployment 'deployment1'
            conf.use_deployment 'deployment1', :on => 'test'
            assert_equal 1, conf.deployments['test'].size
        end
    end
end


