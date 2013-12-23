require 'syskit/test/self'
require './test/fixtures/simple_composition_model'

describe Syskit::InstanceRequirements do
    include Syskit::Test::Self
    include Syskit::Fixtures::SimpleCompositionModel

    before do
        create_simple_composition_model
    end

    describe "#component_model" do
        it "returns the model if it is not a proxied model" do
            task_m = Syskit::Component.new_submodel
            req = Syskit::InstanceRequirements.new([task_m])
            assert_same task_m, req.component_model
        end

        it "strips out the data service first" do
            task_m = Syskit::Component.new_submodel
            srv_m = Syskit::DataService.new_submodel
            task_m.provides srv_m, :as => 'test'
            req = Syskit::InstanceRequirements.new([task_m.test_srv])
            assert_same task_m, req.component_model
        end

        it "returns the proxied component model if its required model is one" do
            task_m = Syskit::Component.new_submodel
            srv_m = Syskit::DataService.new_submodel
            req = Syskit::InstanceRequirements.new([task_m,srv_m])
            assert_same task_m, req.component_model
        end
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
        it "picks the port on the selected service if there is one" do
            req.select_service(simple_task_model.srv_srv)
            assert req.find_port 'srv_in'
            assert req.find_port 'srv_out'
        end
        it "picks the port on the selected service if there is one" do
            req.select_service(simple_task_model.srv_srv)
            assert req.find_port 'srv_in'
            assert req.find_port 'srv_out'
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
            assert_equal simple_task_model.srv_srv, srv.service
        end
        it "returns nil on non-existent services" do
            assert_equal nil, req.find_data_service('bla')
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
        it "should return the expected model if the requirements represent a service of a subtype" do
            s = Syskit::DataService.new_submodel
            subs = s.new_submodel
            req = Syskit::InstanceRequirements.new([subs])
            req = req.find_data_service_from_type(s)
            assert_same s, req.service.model
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
            c = Syskit::TaskContext.new_submodel { provides s, :as => 'srv' }
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
            assert_raises(Syskit::InvalidSelection) do
                simple_composition_model.use('srv' => Syskit::TaskContext.new_submodel)
            end
        end
        it "should raise if a name to value mapping is invalid for a known child, even though the model does not respond to #fullfills?" do
            simple_composition_model.overload('srv', simple_component_model)
            req = flexmock(:to_instance_requirements => Syskit::TaskContext.new_submodel.to_instance_requirements)
            assert_raises(Syskit::InvalidSelection) do
                simple_composition_model.use('srv' => req)
            end
        end
        it "should allow providing a service submodel as a selection for a composition child" do
            srv_m = Syskit::DataService.new_submodel
            subsrv_m = srv_m.new_submodel
            cmp_m = Syskit::Composition.new_submodel do
                add srv_m, :as => 'test'
            end
            ir = Syskit::InstanceRequirements.new([cmp_m])
            ir.use('test' => subsrv_m)
        end
    end

    describe "#fullfilled_model" do
        it "should return Syskit::Component as first element if the models do not contain any component models" do
            assert_equal Syskit::Component, Syskit::InstanceRequirements.new([]).fullfilled_model[0]
        end
        it "should return Syskit::Component as first element if the model is a data service" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel
            task_m.provides srv_m, :as => 'test'
            assert_equal Syskit::Component, Syskit::InstanceRequirements.new([srv_m]).fullfilled_model[0]
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
            assert_equal [srv1, srv2, Syskit::DataService].to_set, Syskit::InstanceRequirements.new([component_model]).fullfilled_model[1].to_set
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
        it "accepts selecting services from placeholder tasks if the set of models in the task matches the set of models in the instance requirements" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit.proxy_task_model_for([srv_m])

            req = Syskit::InstanceRequirements.new([srv_m])
            srv = task_m.find_data_service_from_type(srv_m)
            req.select_service(srv)
            assert_equal srv, req.service
            instanciated = req.instanciate(plan)
            assert_equal srv, instanciated.model
        end
    end

    describe "#instanciate" do
        it "merges self with unselected services into the task's instance requirements" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task = task_m.new)
            ir = Syskit::InstanceRequirements.new([task_m])
            ir_component_model = Syskit::InstanceRequirements.new([task_m])
            flexmock(ir).should_receive(:to_component_model).and_return(ir_component_model)
            flexmock(task_m).should_receive(:new).once.and_return(task)
            flexmock(task.requirements).should_receive(:merge).once.with(ir_component_model)
            ir.instanciate(plan)
        end

        it "resolves the instances inside the requirements before merging them into Task#requirements" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task = task_m.new)
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, :as => 'test'
            ir = cmp_m.use('test' => task)
            cmp = ir.instanciate(plan)
            assert_equal Syskit::InstanceRequirements.new([task_m]), cmp.requirements.resolved_dependency_injection.explicit['test']
            assert_same task, cmp.test_child
        end

        it "does not resolve plain models before merging them into Task#requirements" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task = task_m.new)
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, :as => 'test'
            ir = cmp_m.use('test' => task_m)
            cmp = ir.instanciate(plan)
            assert_equal task_m, cmp.requirements.resolved_dependency_injection.explicit['test']
        end

        it "adds a barrier to make sure that the models' direct dependencies can only be picked by the direct use() flags" do
            model_m = Syskit::Composition.new_submodel
            flexmock(model_m).should_receive(:dependency_injection_names).and_return(%w{child})
            context = Syskit::DependencyInjectionContext.new(Syskit::DependencyInjection.new('child' => model_m))
            flexmock(model_m).should_receive(:instanciate).
                with(any, lambda { |c| !c.current_state.direct_selection_for('child') }, any).
                once.pass_thru
            model_m.to_instance_requirements.instanciate(plan, context)
        end

        it "adds a barrier to make sure that the models' direct dependencies can only be picked by the direct use() flags even if a service is selected" do
            model_m = Syskit::Composition.new_submodel
            model_m.provides Syskit::DataService, :as => 'test'
            flexmock(model_m).should_receive(:dependency_injection_names).and_return(%w{child})
            context = Syskit::DependencyInjectionContext.new(Syskit::DependencyInjection.new('child' => model_m))
            flexmock(model_m).should_receive(:instanciate).
                with(any, lambda { |c| !c.current_state.direct_selection_for('child') }, any).
                once.pass_thru
            model_m.test_srv.to_instance_requirements.instanciate(plan, context)
        end
    end

    describe "#unselect_service" do
        it "strips off the data service if there is one" do
            task_m = Syskit::TaskContext.new_submodel
            srv_m = Syskit::DataService.new_submodel
            task_m.provides srv_m, :as => 'test'
            req = Syskit::InstanceRequirements.new([task_m.test_srv])
            req.unselect_service
            assert_same task_m, req.base_model
            assert_same task_m, req.model
        end
        it "does nothing if the requirements point to no service" do
            task_m = Syskit::TaskContext.new_submodel
            req = Syskit::InstanceRequirements.new([task_m])
            req.unselect_service
            assert_same task_m, req.base_model
            assert_same task_m, req.model
        end
    end

    describe "#narrow_model" do
        attr_reader :srv_m, :task_m, :cmp_m
        before do
            srv_m = @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, :as => 'test'
                

            @cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, :as => 'test0'
            cmp_m.specialize cmp_m.test0_child => task_m do
                add srv_m, :as => 'test1'
            end
        end

        it "applies the complete context to compute the narrowed model" do
            di = Syskit::InstanceRequirements.new([cmp_m])
            di.use('test0' => task_m)
            model = di.narrow_model
            assert model.is_specialization?
        end
    end

    describe "#merge" do
        attr_reader :srv_m, :task_m, :with_service, :without_service
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, :as => 'test'

            @with_service = Syskit::InstanceRequirements.new([task_m.test_srv])
            @without_service = Syskit::InstanceRequirements.new([task_m])
        end

        it "should keep the selected service from the receiver if there is one" do
            assert_equal task_m.test_srv, with_service.merge(without_service).service
        end
        it "should keep the selected service from the argument if there is one" do
            assert_equal task_m.test_srv, without_service.merge(with_service).service
        end
        it "should keep the selected service if both have a compatible selection" do
            assert_equal task_m.test_srv, with_service.merge(with_service.dup).service
        end
    end

    describe "#self_port_to_component_port" do
        it "does not modify ports if the model is a component model already" do
            task_m = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end
            ir = Syskit::InstanceRequirements.new([task_m])
            port = ir.out_port
            resolved = port.to_component_port
            assert_equal resolved, port
        end
        it "does port mapping if the model is a service" do
            srv_m = Syskit::DataService.new_submodel do
                output_port 'srv_out', '/double'
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port 'out', '/double'
            end
            task_m.provides srv_m, :as => 'test'

            ir = Syskit::InstanceRequirements.new([task_m.test_srv])
            port = ir.srv_out_port
            resolved = port.to_component_port
            assert_equal resolved, ir.to_component_model.out_port
        end
    end

    describe "#as_plan" do
        attr_reader :task_m, :srv_m
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, :as => 'test'
        end
        it "should return a planning pattern for itself" do
            ir = Syskit::InstanceRequirements.new([task_m])
            plan.add(task = ir.as_plan)
            assert_kind_of task_m, task
            assert task.planning_task
            assert_equal ir, task.planning_task.requirements
        end

        it "should allow to be created from a service selection" do
            ir = Syskit::InstanceRequirements.new([task_m.test_srv])
            plan.add(task = ir.as_plan)
            assert_kind_of task_m, task
            assert task.planning_task
            assert_equal ir, task.planning_task.requirements
        end
    end
end

