require 'syskit/test'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceRequirements do
    include Syskit::SelfTest
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
    end

    describe "#==" do
        describe "the models are identical and a service is selected" do
            attr_reader :a, :b

            before do
                simple_component_model.provides simple_service_model, :as => 'srv2'
                @a = Syskit::InstanceRequirements.new([simple_component_model])
                @b = Syskit::InstanceRequirements.new([simple_component_model])
            end

            it "should return true if both select the same service" do
                a.select_service(simple_component_model.srv_srv)
                b.select_service(simple_component_model.srv_srv)
                assert_equal a, b
                assert_equal b, a
            end
            it "should return false if one has a service but not the other" do
                a.select_service(simple_component_model.srv_srv)
                b.select_service(simple_component_model.srv2_srv)
                refute_equal a, b
                refute_equal b, a
            end
            it "should return false if both have services but it differs" do
                a.select_service(simple_component_model.srv_srv)
                refute_equal a, b
                refute_equal b, a
            end
        end
    end

    describe "#find_port" do
        attr_reader :req
        before do
            @req = Syskit::InstanceRequirements.new([simple_task_model])
        end
        it "gives access to a port" do
            port = req.find_port('out')
            assert_equal Syskit::Models::OutputPort.new(req, simple_task_model.find_output_port('out').orogen_model), port
        end
        it "returns nil on non-existent ports" do
            assert_equal nil, req.find_port('bla')
        end
        it "raises AmbiguousPortName if the same port is present on multiple models" do
            srv_model = Syskit::DataService.new_submodel { output_port 'out', '/double' }
            task_model = Syskit::TaskContext.new_submodel { output_port 'out', '/double' }
            req = Syskit::InstanceRequirements.new([srv_model, task_model])
            assert_raises(Syskit::AmbiguousPortName) { req.find_port('out') }
        end
    end

    describe "#find_data_service" do
        attr_reader :req
        before do
            @req = Syskit::InstanceRequirements.new([simple_task_model])
        end
        it "gives access to a service" do
            srv = req.find_data_service 'srv'
            assert srv
            assert_equal req.models, srv.models
            assert_equal simple_task_model.srv_srv, srv.service
        end
        it "returns nil on non-existent services" do
            assert_equal nil, req.find_data_service('bla')
        end
        it "raises if used on a requirement that does not have a task context" do
            assert_raises(ArgumentError) { Syskit::InstanceRequirements.new.find_data_service('bla') }
        end
    end

    describe "#find_child" do
        attr_reader :req
        before do
            @req = simple_composition_model.use(simple_task_model)
        end

        it "should give access to a composition child" do
            child = req.find_child('srv')
            assert_kind_of Syskit::Models::CompositionChild, child
            assert_equal 'srv', child.child_name
            assert_equal req, child.composition_model
        end
        it "raises if called on a non-composition" do
            assert_raises(ArgumentError) { Syskit::InstanceRequirements.new([Syskit::TaskContext.new_submodel]).find_child('child') }
        end
    end

    describe "#method_missing" do
        attr_reader :req
        before do
            @req = Syskit::InstanceRequirements.new([simple_task_model])
        end

        it "gives access to ports using the _port suffix" do
            flexmock(req).should_receive(:find_port).with('bla').and_return(obj = Object.new)
            assert_equal obj, req.bla_port
        end
        it "raises if a non-existent port is accessed" do
            flexmock(req).should_receive(:find_port).with('bla').and_return(nil)
            assert_raises(NoMethodError) { req.bla_port }
        end
        it "gives access to data services using the _srv suffix" do
            flexmock(req).should_receive(:find_data_service).with('bla').and_return(obj = Object.new)
            assert_equal obj, req.bla_srv
        end
        it "raises if a non-existent port is accessed" do
            flexmock(req).should_receive(:find_data_service).with('bla').and_return(nil)
            assert_raises(NoMethodError) { req.bla_srv }
        end
    end

    describe "an InstanceRequirements with a data service selected" do
        attr_reader :req
        before do
            spec = Syskit::InstanceRequirements.new([simple_task_model])
            @req = spec.find_data_service('srv')
        end

        it "should give access to the port via the service ports" do
            port = req.srv_out_port
            assert_equal Syskit::Models::OutputPort.new(req, simple_task_model.find_output_port('out').orogen_model, 'srv_out'), port
        end
    end

    describe "the child of an InstanceRequirements" do
        attr_reader :req
        attr_reader :child
        before do
            @req = simple_composition_model.use(simple_task_model)
            @child = req.find_child('srv')
        end

        it "should give access to the child ports" do
            port = child.find_port('srv_out')
            assert_equal Syskit::Models::OutputPort.new(child, simple_service_model.find_output_port('srv_out').orogen_model), port
        end
    end

    describe "#find_data_service_from_type" do
        it "should return the receiver if the service is explicitly listed in models" do
            s = Syskit::DataService.new_submodel
            subs = s.new_submodel
            req = Syskit::InstanceRequirements.new([subs])
            assert_same req, req.find_data_service_from_type(s)
        end

        it "should return a bound data service if the service is provided by a component model" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel { provides s, :as => 's' }
            subc = c.new_submodel
            req = Syskit::InstanceRequirements.new([subc])
            flexmock(req).should_receive(:find_data_service_from_type).with(s).and_return(obj = Object.new)

            assert_equal obj, req.find_data_service_from_type(s)
        end
        it "should not raise if the contained component model has multiple services of the requested type, but one is selected in the InstanceRequirements object itself" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel do
                provides s, :as => 's0'
                provides s, :as => 's1'
            end
            req = Syskit::InstanceRequirements.new([c])
            req.select_service(c.s0_srv)
            assert_same req, req.find_data_service_from_type(s)
        end

        it "should raise if the data service is ambiguous w.r.t. the contained component model" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel do
                provides s, :as => 'srv'
                provides s, :as => 'srv1'
            end
            req = Syskit::InstanceRequirements.new([c])
            assert_raises(Syskit::AmbiguousServiceSelection) { req.find_data_service_from_type(s) }
        end
        it "should raise if the data service is provided by both a component model and a service" do
            s = Syskit::DataService.new_submodel
            s2 = s.new_submodel
            c = Syskit::Component.new_submodel { provides s, :as => 'srv' }
            req = Syskit::InstanceRequirements.new([c, s2])
            assert_raises(Syskit::AmbiguousServiceSelection) { req.find_data_service_from_type(s) }
        end
        it "should return nil if there are no matches" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel
            key = Syskit::DataService.new_submodel
            req = Syskit::InstanceRequirements.new([key])

            assert !req.find_data_service_from_type(s)
        end
    end

    describe "#use" do
        it "should not try to verify a name to value mapping for a known child if the value is a string" do
            simple_composition_model.overload('srv', simple_component_model)
            simple_composition_model.use('srv' => 'device')
        end
        it "should raise if a name to value mapping is invalid for a known child" do
            simple_composition_model.overload('srv', simple_component_model)
            assert_raises(ArgumentError) do
                simple_composition_model.use('srv' => Syskit::TaskContext.new_submodel)
            end
        end
    end

    describe "#fullfilled_model" do
        it "should return Syskit::Component as first element if the models do not contain any component models" do
            assert_equal Syskit::Component, Syskit::InstanceRequirements.new([]).fullfilled_model[0]
        end
        it "should return the component model as first element" do
            component_model = Syskit::Component.new_submodel
            assert_equal component_model, Syskit::InstanceRequirements.new([component_model]).fullfilled_model[0]
        end
        it "should return an empty list as second element if no data services are present" do
            component_model = Syskit::Component.new_submodel
            assert_equal [], Syskit::InstanceRequirements.new([component_model]).fullfilled_model[1]
        end
        it "should list the data services as second element" do
            srv1, srv2 = Syskit::DataService.new_submodel, Syskit::DataService.new_submodel
            component_model = Syskit::Component.new_submodel do
                provides srv1, :as => "1"
                provides srv2, :as => "2"
            end
            assert_equal [srv1, srv2].to_set, Syskit::InstanceRequirements.new([component_model]).fullfilled_model[1].to_set
        end
        it "should return the required arguments as third element" do
            arguments = Hash['an argument' => 'for the task']
            req = Syskit::InstanceRequirements.new([]).with_arguments(arguments)
            assert_equal arguments, req.fullfilled_model[2]
        end
    end

    describe "#select_service" do
        it "raises ArgumentError if the given service is not provided by the current requirements" do
            req = Syskit::InstanceRequirements.new([Syskit::TaskContext.new_submodel])
            task_m = Syskit::TaskContext.new_submodel { provides Syskit::DataService.new_submodel, :as => 'srv' }
            assert_raises(ArgumentError) { req.select_service(task_m.srv_srv) }
        end
    end
end

