# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::InstanceRequirements do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :stub_t
    before do
        @stub_t = stub_type "/test_t"
        create_simple_composition_model
    end

    describe "#with_arguments" do
        attr_reader :req, :not_marshallable
        before do
            @task_m = Syskit::TaskContext.new_submodel do
                argument :key
            end
            @req = Syskit::InstanceRequirements.new
            @not_marshallable = Object.new
            not_marshallable.extend Roby::DRoby::Unmarshallable
        end
        it "sets the argument" do
            req = Syskit::InstanceRequirements.new([@task_m])
            req.with_arguments(key: 10)
            task = req.instanciate(Roby::Plan.new)
            assert_equal 10, task.key
        end
        it "does not issue a deprecation warning for symbol keys" do
            flexmock(Roby).should_receive(:warn_deprecated).never
            req.with_arguments(key: 10)
        end
        it "issues a deprecation warning for string keys and converts them" do
            req = Syskit::InstanceRequirements.new([@task_m])
            flexmock(Roby).should_receive(:warn_deprecated).once
            req.with_arguments("key" => 10)
            task = req.instanciate(Roby::Plan.new)
            assert_equal 10, task.key
        end
        it "raises if the argument cannot be marshalled under DRoby" do
            e = assert_raises(Roby::NotMarshallable) do
                req.with_arguments(key: not_marshallable)
            end
            assert_equal "values used as task arguments must be marshallable, attempting to set key to #{not_marshallable} of class Object, which is not", e.message
        end

        it "generates the same error message than setting the task argument directly" do
            actual_e = assert_raises(Roby::NotMarshallable) do
                req.with_arguments(key: not_marshallable)
            end
            task = @task_m.new
            expected_e = assert_raises(Roby::NotMarshallable) do
                task.key = not_marshallable
            end
            assert_equal expected_e.message, actual_e.message
        end
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
            task_m.provides srv_m, as: "test"
            req = Syskit::InstanceRequirements.new([task_m.test_srv])
            assert_same task_m, req.component_model
        end

        it "returns the proxied component model if its required model is one" do
            task_m = Syskit::Component.new_submodel
            srv_m = Syskit::DataService.new_submodel
            req = Syskit::InstanceRequirements.new([task_m, srv_m])
            assert_same task_m, req.component_model
        end
    end

    describe "#==" do
        describe "the models are identical and a service is selected" do
            attr_reader :a, :b

            before do
                simple_component_model.provides simple_service_model, as: "srv2"
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
            port = req.find_port("out")
            assert_equal Syskit::Models::OutputPort.new(req, simple_task_model.find_output_port("out").orogen_model), port
        end
        it "returns nil on non-existent ports" do
            assert_nil req.find_port("bla")
        end
        it "picks the port on the selected service if there is one" do
            req.select_service(simple_task_model.srv_srv)
            assert req.find_port "srv_in"
            assert req.find_port "srv_out"
        end
        it "picks the port on the selected service if there is one" do
            req.select_service(simple_task_model.srv_srv)
            assert req.find_port "srv_in"
            assert req.find_port "srv_out"
        end
    end

    describe "#find_data_service" do
        attr_reader :req
        before do
            @req = Syskit::InstanceRequirements.new([simple_task_model])
        end
        it "gives access to a service" do
            srv = req.find_data_service "srv"
            assert srv
            assert_equal simple_task_model.srv_srv, srv.service
        end
        it "returns nil on non-existent services" do
            assert_nil req.find_data_service("bla")
        end
    end

    describe "#find_child" do
        attr_reader :req
        before do
            @req = simple_composition_model.use(simple_task_model)
        end

        it "should give access to a composition child" do
            child = req.find_child("srv")
            assert_kind_of Syskit::Models::CompositionChild, child
            assert_equal "srv", child.child_name
            assert_equal req, child.composition_model
        end
        it "raises if called on a non-composition" do
            assert_raises(ArgumentError) { Syskit::InstanceRequirements.new([Syskit::TaskContext.new_submodel]).find_child("child") }
        end
    end

    describe "#method_missing" do
        attr_reader :req
        before do
            @req = Syskit::InstanceRequirements.new([simple_task_model])
        end

        it "gives access to ports using the _port suffix" do
            flexmock(req).should_receive(:find_port).with("bla").and_return(obj = Object.new)
            assert_equal obj, req.bla_port
        end
        it "raises if a non-existent port is accessed" do
            flexmock(req).should_receive(:find_port).with("bla").and_return(nil)
            assert_raises(NoMethodError) { req.bla_port }
        end
        it "gives access to data services using the _srv suffix" do
            flexmock(req).should_receive(:find_data_service).with("bla").and_return(obj = Object.new)
            assert_equal obj, req.bla_srv
        end
        it "raises if a non-existent port is accessed" do
            flexmock(req).should_receive(:find_data_service).with("bla").and_return(nil)
            assert_raises(NoMethodError) { req.bla_srv }
        end
    end

    describe "an InstanceRequirements with a data service selected" do
        attr_reader :req
        before do
            spec = Syskit::InstanceRequirements.new([simple_task_model])
            @req = spec.find_data_service("srv")
        end

        it "should give access to the port via the service ports" do
            port = req.srv_out_port
            assert_equal Syskit::Models::OutputPort.new(req, simple_task_model.find_output_port("out").orogen_model, "srv_out"), port
        end
    end

    describe "the child of an InstanceRequirements" do
        attr_reader :req
        attr_reader :child
        before do
            @req = simple_composition_model.use(simple_task_model)
            @child = req.find_child("srv")
        end

        it "should give access to the child ports" do
            port = child.find_port("srv_out")
            assert_equal Syskit::Models::OutputPort.new(child, simple_service_model.find_output_port("srv_out").orogen_model), port
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
            c = Syskit::Component.new_submodel { provides s, as: "s" }
            subc = c.new_submodel
            req = Syskit::InstanceRequirements.new([subc])
            flexmock(req).should_receive(:find_data_service_from_type).with(s).and_return(obj = Object.new)

            assert_equal obj, req.find_data_service_from_type(s)
        end
        it "should not raise if the contained component model has multiple services of the requested type, but one is selected in the InstanceRequirements object itself" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel do
                provides s, as: "s0"
                provides s, as: "s1"
            end
            req = Syskit::InstanceRequirements.new([c])
            req.select_service(c.s0_srv)
            assert_same req, req.find_data_service_from_type(s)
        end

        it "should raise if the data service is ambiguous w.r.t. the contained component model" do
            s = Syskit::DataService.new_submodel
            c = Syskit::Component.new_submodel do
                provides s, as: "srv"
                provides s, as: "srv1"
            end
            req = Syskit::InstanceRequirements.new([c])
            assert_raises(Syskit::AmbiguousServiceSelection) { req.find_data_service_from_type(s) }
        end
        it "should raise if the data service is provided by both a component model and a service" do
            s = Syskit::DataService.new_submodel
            s2 = s.new_submodel
            c = Syskit::TaskContext.new_submodel { provides s, as: "srv" }
            req = Syskit::InstanceRequirements.new([c, s2])
            assert_raises(Syskit::AmbiguousServiceSelection) { req.find_data_service_from_type(s) }
        end
        it "should return nil if there are no matches" do
            s = Syskit::DataService.new_submodel
            key = Syskit::DataService.new_submodel
            req = Syskit::InstanceRequirements.new([key])

            assert !req.find_data_service_from_type(s)
        end
    end

    describe "#use" do
        attr_reader :srv_m, :cmp_m, :task_m
        before do
            @srv_m = Syskit::DataService.new_submodel
            @cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: "test"
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
        end
        it "should not try to verify a name to value mapping for a known child if the value is a string" do
            simple_composition_model.overload("srv", simple_component_model)
            simple_composition_model.use("srv" => "device")
        end
        it "should raise if a name to value mapping is invalid for a known child" do
            simple_composition_model.overload("srv", simple_component_model)
            assert_raises(Syskit::InvalidSelection) do
                simple_composition_model.use("srv" => Syskit::TaskContext.new_submodel)
            end
        end
        it "should raise if a name to value mapping is invalid for a known child, even though the model does not respond to #fullfills?" do
            simple_composition_model.overload("srv", simple_component_model)
            req = flexmock(to_instance_requirements: Syskit::TaskContext.new_submodel.to_instance_requirements)
            assert_raises(Syskit::InvalidSelection) do
                simple_composition_model.use("srv" => req)
            end
        end
        it "should allow providing a service submodel as a selection for a composition child" do
            srv_m = Syskit::DataService.new_submodel
            subsrv_m = srv_m.new_submodel
            cmp_m = Syskit::Composition.new_submodel do
                add srv_m, as: "test"
            end
            ir = Syskit::InstanceRequirements.new([cmp_m])
            ir.use("test" => subsrv_m)
        end

        it "should raise if a child selection is ambiguous" do
            task_m.provides srv_m, as: "ambiguous"
            cmp_m.use("test" => task_m)
        end
        it "should allow selecting a service explicitly" do
            task_m.provides srv_m, as: "ambiguous"
            req = cmp_m.use("test" => task_m.test_srv)
            assert_equal task_m.test_srv, req.resolved_dependency_injection.explicit["test"]
        end
    end

    describe "#fullfilled_model" do
        it "should return Syskit::Component as first element if the models do not contain any component models" do
            assert_equal Syskit::Component, Syskit::InstanceRequirements.new([]).fullfilled_model[0]
        end
        it "should return Syskit::Component as first element if the model is a data service" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel
            task_m.provides srv_m, as: "test"
            assert_equal Syskit::Component, Syskit::InstanceRequirements.new([srv_m]).fullfilled_model[0]
        end
        it "should return the component model as first element" do
            component_model = Syskit::Component.new_submodel
            assert_equal component_model, Syskit::InstanceRequirements.new([component_model]).fullfilled_model[0]
        end
        it "should return an empty list as second element if no data services are present" do
            component_model = Syskit::Component.new_submodel
            assert_equal [Syskit::AbstractComponent],
                         Syskit::InstanceRequirements.new([component_model]).fullfilled_model[1]
        end
        it "should list the data services as second element" do
            srv1 = Syskit::DataService.new_submodel
            srv2 = Syskit::DataService.new_submodel
            component_model = Syskit::Component.new_submodel do
                provides srv1, as: "1"
                provides srv2, as: "2"
            end
            ir = Syskit::InstanceRequirements.new([component_model])
            assert_equal [srv1, srv2, Syskit::DataService,
                          Syskit::AbstractComponent].to_set,
                         ir.fullfilled_model[1].to_set
        end
        it "should return the required arguments as third element" do
            arguments = Hash[argument: "for the task"]
            req = Syskit::InstanceRequirements.new([]).with_arguments(**arguments)
            assert_equal arguments, req.fullfilled_model[2]
        end
    end

    describe "#select_service" do
        it "raises ArgumentError if the given service is not provided by the current requirements" do
            req = Syskit::InstanceRequirements.new([Syskit::TaskContext.new_submodel])
            task_m = Syskit::TaskContext.new_submodel { provides Syskit::DataService.new_submodel, as: "srv" }
            assert_raises(ArgumentError) { req.select_service(task_m.srv_srv) }
        end
        it "accepts selecting services from placeholder tasks if the set of models in the task matches the set of models in the instance requirements" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = srv_m.placeholder_model

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
            task = task_m.new
            ir = Syskit::InstanceRequirements.new([task_m])
            ir_component_model = Syskit::InstanceRequirements.new([task_m])
            flexmock(ir).should_receive(:to_component_model).and_return(ir_component_model)
            flexmock(task_m).should_receive(:new).once.and_return(task)
            flexmock(task.requirements).should_receive(:merge).once.with(ir_component_model, any)
            ir.instanciate(plan)
        end

        it "resolves the instances inside the requirements before merging them into Task#requirements" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task = task_m.new)
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "test"
            ir = cmp_m.use("test" => task)
            assert !ir.can_use_template?
            cmp = ir.instanciate(plan)
            assert_equal Syskit::InstanceRequirements.new([task_m]), cmp.requirements.resolved_dependency_injection.explicit["test"]
            assert_same task, cmp.test_child
        end

        it "does not resolve plain models before merging them into Task#requirements" do
            task_m = Syskit::TaskContext.new_submodel
            plan.add(task_m.new)
            cmp_m = Syskit::Composition.new_submodel
            cmp_m.add task_m, as: "test"
            ir = cmp_m.use("test" => task_m)
            cmp = ir.instanciate(plan)
            assert_equal task_m, cmp.requirements.resolved_dependency_injection.explicit["test"]
        end

        it "adds a barrier to make sure that the models' direct dependencies can only be picked by the direct use() flags" do
            model_m = Syskit::Composition.new_submodel
            flexmock(model_m).should_receive(:dependency_injection_names).and_return(%w{child})
            context = Syskit::DependencyInjectionContext.new(Syskit::DependencyInjection.new("child" => model_m))
            has_no_child_selection =
                ->(c) { !c.current_state.direct_selection_for("child") }
            flexmock(model_m).should_receive(:instanciate)
                             .with(any, has_no_child_selection, any)
                             .once.pass_thru
            model_m.to_instance_requirements.instanciate(plan, context)
        end

        it "adds a barrier to make sure that the models' direct dependencies can only be picked by the direct use() flags even if a service is selected" do
            model_m = Syskit::Composition.new_submodel
            model_m.provides Syskit::DataService, as: "test"
            flexmock(model_m).should_receive(:dependency_injection_names).and_return(%w{child})
            context = Syskit::DependencyInjectionContext.new(Syskit::DependencyInjection.new("child" => model_m))
            has_no_child_selection =
                ->(c) { !c.current_state.direct_selection_for("child") }
            flexmock(model_m).should_receive(:instanciate)
                             .with(any, has_no_child_selection, any)
                             .once.pass_thru
            model_m.test_srv.to_instance_requirements.instanciate(plan, context)
        end

        it "marks the task as abstract if abstract? is true" do
            task_m = Syskit::Component.new_submodel
            ir = task_m.to_instance_requirements.abstract
            assert ir.instanciate(plan).abstract?
        end

        it "ensures that the task's requirements have abstract set if abstract is set on self" do
            task_m = Syskit::Component.new_submodel
            ir = task_m.to_instance_requirements.abstract
            assert ir.instanciate(plan).requirements.abstract?
        end

        it "does not mark the task as abstract if abstract? is false" do
            task_m = Syskit::Component.new_submodel
            ir = task_m.to_instance_requirements
            assert !ir.instanciate(plan).abstract?
        end

        it "ensures that the task's requirements do not have abstract set if abstract is not set on self" do
            task_m = Syskit::Component.new_submodel
            ir = task_m.to_instance_requirements
            refute ir.instanciate(plan).requirements.abstract?
        end
    end

    describe "#unselect_service" do
        it "strips off the data service if there is one" do
            task_m = Syskit::TaskContext.new_submodel
            srv_m = Syskit::DataService.new_submodel
            task_m.provides srv_m, as: "test"
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
            task_m.provides srv_m, as: "test"

            @cmp_m = Syskit::Composition.new_submodel
            cmp_m.add srv_m, as: "test0"
            cmp_m.specialize cmp_m.test0_child => task_m do
                add srv_m, as: "test1"
            end
        end

        it "applies the complete context to compute the narrowed model" do
            di = Syskit::InstanceRequirements.new([cmp_m])
            di.use("test0" => task_m)
            model = di.narrow_model
            assert model.is_specialization?
        end
    end

    describe "#merge" do
        attr_reader :srv_m, :task_m, :with_service, :without_service
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"

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
        it "sets abstract? to false by default if any of the two IRs are not abstract" do
            ir = task_m.to_instance_requirements.abstract.merge(task_m.to_instance_requirements)
            assert !ir.abstract?
            ir = task_m.to_instance_requirements.merge(task_m.to_instance_requirements.abstract)
            assert !ir.abstract?
        end
        it "OR-ed abstract? if any of the two IRs is abstract and keep_abstract is true" do
            ir = task_m.to_instance_requirements.abstract.merge(task_m.to_instance_requirements, keep_abstract: true)
            assert ir.abstract?
            ir = task_m.to_instance_requirements.merge(task_m.to_instance_requirements.abstract, keep_abstract: true)
            assert ir.abstract?
        end
    end

    describe "#self_port_to_component_port" do
        it "does not modify ports if the model is a component model already" do
            task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            ir = Syskit::InstanceRequirements.new([task_m])
            port = ir.out_port
            resolved = port.to_component_port
            assert_equal resolved, port
        end
        it "does port mapping if the model is a service" do
            srv_m = Syskit::DataService.new_submodel do
                output_port "srv_out", "/double"
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            task_m.provides srv_m, as: "test"

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
            task_m.provides srv_m, as: "test"
        end
        it "returns a planning pattern for itself" do
            ir = Syskit::InstanceRequirements.new([task_m])
            plan.add(task = ir.as_plan)
            assert_kind_of task_m, task
            assert task.planning_task
            assert_equal ir, task.planning_task.requirements
        end

        it "can be created from a service selection" do
            ir = Syskit::InstanceRequirements.new([task_m.test_srv])
            plan.add(task = ir.as_plan)
            assert_kind_of task_m, task
            assert task.planning_task
            assert_equal ir, task.planning_task.requirements
        end

        it "passes arguments to the generated pattern" do
            @task_m.argument :foo
            ir = Syskit::InstanceRequirements.new([@task_m])
            task = ir.as_plan(foo: 10)
            assert_equal 10, task.planning_task.requirements.arguments[:foo]
        end

        it "does not modify self when passing arguments" do
            @task_m.argument :foo
            ir = Syskit::InstanceRequirements.new([@task_m])
            ir.as_plan(foo: 10)
            assert_nil ir.arguments[:foo]
        end
    end

    describe "#as" do
        attr_reader :parent_srv_m, :srv_m, :task_m
        before do
            @parent_srv_m = Syskit::DataService.new_submodel
            @srv_m = Syskit::DataService.new_submodel
            srv_m.provides parent_srv_m
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
        end

        it "selects the component model's service that matches the given service model" do
            ir = task_m.to_instance_requirements
            ir = ir.as(parent_srv_m)
            expected = task_m.test_srv.as(srv_m).to_instance_requirements
            assert_equal expected, ir.selected
        end

        it "allows to override an already selected service by one of its parent models" do
            ir = task_m.to_instance_requirements
            ir.select_service(task_m.test_srv)
            ir = ir.as(parent_srv_m)

            expected = task_m.test_srv.as(srv_m).attach(ir.model)
            assert_equal expected, ir.service
        end
    end

    describe "#each_child" do
        it "does not trigger a modification-during-iteration exception because of promotion" do
            srv_m = Syskit::DataService.new_submodel
            c0 = Syskit::Composition.new_submodel do
                add srv_m, as: "test2"
            end
            c1 = c0.new_submodel do
                add srv_m, as: "test1"
            end
            ir = c1.to_instance_requirements
            # InstanceRequirements#each_child has a tendency to iterate over the
            # underlying's model children. This caused a hash
            # modification-during-iteration when some promotions were needed
            #
            # So, everything fine's if the following passes
            ir.each_child.to_a
        end
    end

    describe "#to_action_model" do
        it "uses the task model as return value for the action" do
            task_m = Syskit::TaskContext.new_submodel
            action_m = Syskit::InstanceRequirements.new([task_m]).to_action_model
            assert_equal task_m, action_m.returned_type
        end
        it "defines a required argument for each task argument without default" do
            action_m = to_action_model { argument :test }
            assert action_m.find_arg(:test).required
        end
        it "defines an optional argument with default for each task argument that has a static default" do
            action_m = to_action_model { argument :test, default: 10 }
            refute action_m.find_arg(:test).required
            assert_equal 10, action_m.find_arg(:test).default
        end
        it "defines an optional argument without default for each task argument that has a delayed argument as default" do
            action_m = to_action_model { argument :test, default: from(:parent_task) }
            refute action_m.find_arg(:test).required
            refute action_m.find_arg(:test).default
        end
        it "propagates the argument's documentation" do
            action_m = to_action_model { argument :test, doc: "the documentation" }
            assert_equal "the documentation", action_m.find_arg(:test).doc
        end
        it "ignores the argument from its root model" do
            action_m = to_action_model
            refute action_m.has_arg?(:orocos_name)
        end

        # Helper method that creates a component model, the corresponding
        # InstanceRequirements and then the action model
        def to_action_model(&block)
            task_m = Syskit::TaskContext.new_submodel(&block)
            Syskit::InstanceRequirements.new([task_m]).to_action_model
        end
    end

    describe "the deployment groups" do
        before do
            @task_m = Syskit::RubyTaskContext.new_submodel
            @ir = Syskit::InstanceRequirements.new([@task_m])
        end
        it "annotates the instanciated task with the deployment group" do
            deployment = @ir.deployment_group
                            .use_ruby_tasks(Hash[@task_m => "test"], on: "stubs")
            task = @ir.instanciate(plan)
            assert_equal deployment, task.requirements.deployment_group
                                         .find_all_suitable_deployments_for(task).map(&:first)
        end
        it "applies the group post-template" do
            @ir.instanciate(plan)
            deployment = @ir.deployment_group
                            .use_ruby_tasks(Hash[@task_m => "test"], on: "stubs")
            task = @ir.instanciate(plan)
            assert_equal deployment, task.requirements.deployment_group
                                         .find_all_suitable_deployments_for(task).map(&:first)
        end
    end

    describe "droby marshalling" do
        it "should be able to be marshalled and unmarshalled" do
            assert_droby_compatible(Syskit::InstanceRequirements.new)
        end
    end

    describe "#bind" do
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            @task_m.provides @srv_m, as: "test"
            @ir = Syskit::InstanceRequirements.new([@srv_m])
        end
        it "binds the task to the model" do
            # TODO: this is not coherent. The value returned by #bind
            # does not match what other
            #
            # However, since #bind is used for the return value of
            # InstanceRequirements#instanciate, changing this would have
            # far-reaching consequences that I can't deal with right now
            #
            # I elected to keep the old behavior until I have the time
            # to dig into it
            task = @task_m.new
            assert_equal task, @ir.bind(task)
        end
        it "raises if the task can't be bound" do
            task = Syskit::TaskContext.new_submodel
            assert_raises(ArgumentError) do
                @ir.bind(task)
            end
        end
        it "is available as resolve for backward-compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated)
                          .with(/resolve.*bind/).once
            task = @task_m.new
            assert_equal task, @ir.resolve(task)
        end
    end

    describe "#try_bind" do
        before do
            @srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel
            @task_m.provides @srv_m, as: "test"
            @ir = Syskit::InstanceRequirements.new([@srv_m])
        end
        it "binds the task to the model" do
            # See comment for #bind
            task = @task_m.new
            assert_equal task, @ir.try_bind(task)
        end
        it "returns nil if the task can't be bound" do
            task = Syskit::TaskContext.new_submodel
            assert_nil @ir.try_bind(task)
        end
        it "is available as resolve for backward-compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated)
                          .with(/try_resolve.*try_bind/).once
            task = @task_m.new
            assert_equal task, @ir.try_resolve(task)
        end
    end
end
