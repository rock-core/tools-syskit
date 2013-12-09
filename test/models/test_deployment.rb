require 'syskit/test'

class TC_Models_Deployment < Test::Unit::TestCase
    include Syskit::SelfTest

    module DefinitionModule
        # Module used when we want to do some "public" models
    end

    def teardown
        super
        begin DefinitionModule.send(:remove_const, :Deployment)
        rescue NameError
        end
    end

    def test_new_submodel
        model = Deployment.new_submodel
        assert(model < Syskit::Deployment)
    end

    def test_new_submodel_registers_the_submodel
        submodel = Deployment.new_submodel
        subsubmodel = submodel.new_submodel

        assert Deployment.submodels.include?(submodel)
        assert Deployment.submodels.include?(subsubmodel)
        assert submodel.submodels.include?(subsubmodel)
    end

    def test_define_from_orogen
        orogen_deployment = Orocos::Spec::Deployment.new
        orogen_task = OroGen::Spec::TaskContext.new(Orocos.default_project)
        orogen_deployment.task "task", orogen_task
        model = Syskit::Deployment.define_from_orogen orogen_deployment, :register => false
        assert_same model.orogen_model, orogen_deployment
    end

    def test_define_from_orogen_does_not_register_anonymous_deployment
        orogen_deployment = Orocos::Spec::Deployment.new
        orogen_task = OroGen::Spec::TaskContext.new(Orocos.default_project)
        orogen_deployment.task "task", orogen_task
        flexmock(::Deployments).should_receive(:const_set).never
        Syskit::Deployment.define_from_orogen orogen_deployment, :register => true
    end

    def test_define_from_orogen_can_register_named_deployments
        orogen_deployment = Orocos::Spec::Deployment.new(nil, "motor_controller")
        orogen_task = OroGen::Spec::TaskContext.new(Orocos.default_project)
        orogen_deployment.task "task", orogen_task
        model = Syskit::Deployment.define_from_orogen orogen_deployment, :register => true
        assert_same model, Deployments::MotorController
    end

    def test_clear_submodels_removes_registered_submodels
        m1 = Deployment.new_submodel
        m2 = Deployment.new_submodel
        m11 = m1.new_submodel

        m1.clear_submodels
        assert !m1.submodels.include?(m11)
        assert Deployment.submodels.include?(m1)
        assert Deployment.submodels.include?(m2)
        assert !Deployment.submodels.include?(m11)

        m11 = m1.new_submodel
        Deployment.clear_submodels
        assert !m1.submodels.include?(m11)
        assert !Deployment.submodels.include?(m1)
        assert !Deployment.submodels.include?(m2)
        assert !Deployment.submodels.include?(m11)
    end
end

describe Syskit::Models::Deployment do
    describe "#new_submodel" do
        it "registers the corresponding orogen to syskit model mapping" do
            submodel = Syskit::Deployment.new_submodel
            subsubmodel = submodel.new_submodel
            assert_equal subsubmodel, Syskit::Deployment.model_for(subsubmodel.orogen_model)
        end
    end
    describe "#clear_submodels" do
        it "removes the corresponding orogen to syskit model mapping" do
            submodel = Syskit::Deployment.new_submodel
            subsubmodel = submodel.new_submodel
            submodel.clear_submodels
            assert !Syskit::Deployment.has_model_for?(subsubmodel.orogen_model)
        end
    end
end
