require 'syskit'
require 'syskit/test'

class TC_Models_Deployment < Test::Unit::TestCase
    include Syskit::SelfTest

    module DefinitionModule
        # Module used when we want to do some "public" models
    end

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
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
