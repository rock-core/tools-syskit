# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::Models::Component do
    include Syskit::Fixtures::SimpleCompositionModel

    attr_reader :stub_t, :other_stub_t
    before do
        @stub_t = stub_type "/test_t"
        @other_stub_t = stub_type "/other_test_t"
    end

    describe "#as_plan" do
        it "creates a plan pattern by calling InstanceRequirementsTask.suplan" do
            c = Syskit::Component.new_submodel
            flexmock(Syskit::InstanceRequirementsTask).should_receive(:subplan).with(c).and_return(obj = Object.new)
            assert_same obj, c.as_plan
        end
    end

    describe "#each_output_port" do
        attr_reader :component_m
        before do
            stub_t = self.stub_t
            @component_m = Syskit::TaskContext.new_submodel do
                output_port "out", stub_t
            end
        end
        it "should yield ports that are bound to the component model" do
            port = component_m.each_output_port.to_a.first
            assert_same component_m, port.component_model
        end
    end

    describe "#each_master_driver_service" do
        it "should list all master devices" do
            task_model = Syskit::TaskContext.new_submodel
            device = Syskit::Device.new_submodel
            task_model.provides device, as: "master1"
            task_model.provides device, as: "master2"
            task_model.provides device, as: "slave", slave_of: "master1"

            assert_equal [task_model.master1_srv, task_model.master2_srv].to_set,
                         task_model.each_master_driver_service.to_set
        end
        it "should ignore pure data services" do
            task_model = Syskit::TaskContext.new_submodel
            device = Syskit::Device.new_submodel
            srv = Syskit::DataService.new_submodel
            task_model.provides device, as: "master1"
            task_model.provides srv, as: "srv"

            assert_equal [task_model.master1_srv], task_model.each_master_driver_service.to_a
        end
    end

    describe "#compute_port_mappings" do
        it "maps service ports to task ports with same name and type" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            mappings = task_m.compute_port_mappings(srv_m)
            assert_equal Hash["out" => "out", "in" => "in"], mappings
        end
        it "will favor a port with the same name if multiple ones have the same type" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                input_port "other_in", stub_t
                output_port "out", stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            mappings = task_m.compute_port_mappings(srv_m)
            assert_equal Hash["out" => "out", "in" => "in"], mappings
        end
        it "allows to choose a port with a different name even if one with the same name exists if the mapping is given explicitely" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                input_port "other_in", stub_t
                output_port "out", stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            mappings = task_m.compute_port_mappings(
                srv_m, "in" => "other_in", "out" => "other_out"
            )
            assert_equal Hash["out" => "other_out", "in" => "other_in"], mappings
        end
        it "maps service ports to task ports with using the explicit port mappings" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                input_port "other_in", stub_t
                output_port "out", stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            mappings = task_m.compute_port_mappings(
                srv_m, "out" => "other_out", "in" => "other_in"
            )
            assert_equal Hash["out" => "other_out", "in" => "other_in"], mappings
        end
        it "raises if a port mapping leads to a port with the wrong direction" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, "out" => "in") }
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, "in" => "out") }
        end
        it "raises if a port mapping leads to a port with the wrong type" do
            stub_t = self.stub_t
            other_stub_t = self.other_stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", other_stub_t
                output_port "out", other_stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, "out" => "in") }
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, "in" => "out") }
        end
        it "can pick a port by type if it is not ambiguous" do
            stub_t = self.stub_t
            other_stub_t = self.other_stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", other_stub_t
                input_port "other_in", stub_t
                output_port "out", other_stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            assert_equal Hash["out" => "other_out", "in" => "other_in"],
                         task_m.compute_port_mappings(srv_m)
        end
        it "raises if mappings are not string-to-string" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "other_in", stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "in", stub_t
                output_port "out", stub_t
            end
            assert_raises(ArgumentError) { task_m.compute_port_mappings(srv_m, flexmock => flexmock) }
        end
        it "raises if multiple component input ports match a service's port type" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                input_port "in", stub_t
                input_port "other_in", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                input_port "srv_in", stub_t
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m) }
        end
        it "raises if multiple component output ports match a service's port type" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                output_port "out", stub_t
                output_port "other_out", stub_t
            end
            srv_m = Syskit::DataService.new_submodel do
                output_port "srv_out", stub_t
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m) }
        end
        it "raises if asked to map multiple service ports to the same task port" do
            stub_t = self.stub_t
            srv_m = Syskit::DataService.new_submodel do
                output_port "bla", stub_t
                output_port "blo", stub_t
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port "test", stub_t
            end
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m) }
            assert_raises(Syskit::InvalidPortMapping) { task_m.compute_port_mappings(srv_m, "bla" => "test") }
        end
        it "allows to map multiple service ports to the same task port explicitly" do
            stub_t = self.stub_t
            srv_m = Syskit::DataService.new_submodel do
                output_port "bla", stub_t
                output_port "blo", stub_t
            end
            task_m = Syskit::TaskContext.new_submodel do
                output_port "test", stub_t
            end
            task_m.compute_port_mappings(srv_m, "bla" => "test", "blo" => "test")
        end
    end

    describe "the dynamic service support" do
        attr_reader :task_m, :srv_m
        before do
            stub_t = self.stub_t
            other_stub_t = self.other_stub_t
            another_stub_t = stub_type "/another_test_t"
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", stub_t
                dynamic_output_port /\w+_out/, another_stub_t
                dynamic_input_port /\w+_in/, other_stub_t
            end
            @srv_m = Syskit::DataService.new_submodel do
                output_port "out", another_stub_t
                input_port "in", other_stub_t
            end
        end

        it "requires reconfiguration by default for all dynamic service-related changes to the model" do
            dyn = task_m.dynamic_service srv_m, as: "dyn" do
            end
            assert dyn.addition_requires_reconfiguration?
            assert dyn.remove_when_unused?
        end

        it "supports the backward-compatible dynamic: argument" do
            flexmock(Roby).should_receive(:warn_deprecated).once
            dyn = task_m.dynamic_service srv_m, as: "dyn", dynamic: true do
            end
            refute dyn.addition_requires_reconfiguration?
            assert dyn.remove_when_unused?
        end

        describe "#find_dynamic_service" do
            it "should return a dynamic service bound to the current component model" do
                srv_m = self.srv_m
                dyn = task_m.dynamic_service srv_m, as: "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                subtask_m = task_m.new_submodel
                assert_equal subtask_m, subtask_m.find_dynamic_service("dyn").component_model
            end
        end

        describe "#dynamic_service" do
            it "should create a DynamicDataService instance" do
                srv_m = self.srv_m
                result = task_m.dynamic_service srv_m, as: "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                assert_kind_of Syskit::Models::DynamicDataService, result
                assert_equal task_m, result.component_model
                assert_equal "dyn", result.name
            end
            it "should raise if no name has been given" do
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m do
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                end
            end
            it "should raise if no block has been given" do
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m, as: "dyn"
                end
            end
            it "should raise if no static nor dynamic ports with the required type exist on the task context to fullfill the required service" do
                other_stub_t = self.other_stub_t
                srv_m = Syskit::DataService.new_submodel { output_port "out", other_stub_t }
                assert_raises(ArgumentError) do
                    task_m.dynamic_service srv_m do
                        provides srv_m, "out" => "#{name}_out"
                    end
                end
            end
            it "should accept services that use static ports as well as dynamic ones" do
                stub_t = self.stub_t
                other_stub_t = self.other_stub_t
                srv_m = Syskit::DataService.new_submodel do
                    input_port "in", other_stub_t
                    output_port "out", stub_t
                end
                task_m.dynamic_service srv_m, as: "srv" do
                    provides srv_m, "out" => "#{name}_out"
                end
            end
            it "should allow to create arguments using #argument" do
                srv_m = Syskit::DataService.new_submodel
                task_m.dynamic_service srv_m, as: "test" do
                    argument "#{name}_arg"
                    provides srv_m
                end
                srv = task_m.require_dynamic_service "test", as: "test"
                assert srv.component_model.has_argument?(:test_arg)
            end
        end

        describe Syskit::Models::DynamicDataService do
            describe "#instanciate" do
                attr_reader :dyn, :srv_m
                before do
                    srv_m = @srv_m = self.srv_m
                    @dyn = task_m.dynamic_service srv_m, as: "dyn" do
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                end

                it "should use DynamicDataService::InstantiationContext to evaluate the block" do
                    flexmock(Syskit::Models::DynamicDataService::InstantiationContext)
                        .new_instances.should_receive(:instance_eval).with(Proc).once.pass_thru
                    dyn.instanciate("service_name")
                end
                it "should return the instanciated service" do
                    context = flexmock(Syskit::Models::DynamicDataService::InstantiationContext).new_instances
                    context.should_receive(:instance_eval).with(Proc).once
                    context.should_receive(:service).and_return(obj = Object.new)
                    assert_same obj, dyn.instanciate("service_name")
                end
                it "should raise if no service has been defined by the block" do
                    context = flexmock(Syskit::Models::DynamicDataService::InstantiationContext).new_instances
                    context.should_receive(:instance_eval).once
                    context.should_receive(:service).once
                    assert_raises(Syskit::InvalidDynamicServiceBlock) { dyn.instanciate("service_name") }
                end
                it "should not allow to have a colliding service name" do
                    task_m.provides Syskit::DataService.new_submodel, as: "srv"
                    assert_raises(ArgumentError) { dyn.instanciate("srv") }
                end
                it "should pass the option hash to the dyn service instantiation block" do
                    received_options = nil
                    srv_m = self.srv_m
                    dyn_srv = task_m.dynamic_service srv_m, as: "ddd" do
                        received_options = options
                        provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                    end
                    options = Hash[test: "bla"]
                    dyn_srv.instanciate("srv", **options)
                    assert_equal options, received_options
                end
                it "should raise if the port mappings do not match ports in the provided service" do
                    stub_t = self.stub_t
                    # Make sure we have a direct static mapping. Otherwise, the
                    # error we will get is that the port cannot be mapped
                    task_m = Syskit::TaskContext.new_submodel { output_port "out", stub_t }
                    srv_m = Syskit::DataService.new_submodel { output_port "out", stub_t }
                    dyn_srv = task_m.dynamic_service srv_m, as: "ddd" do
                        provides srv_m, "does_not_exist" => "#{name}_out"
                    end
                    assert_raises(Syskit::InvalidProvides) { dyn_srv.instanciate("srv") }
                end
                it "should raise if the port mappings do not match ports in the task context" do
                    stub_t = self.stub_t
                    # Make sure we have a direct static mapping. Otherwise, the
                    # error we will get is that the port cannot be mapped
                    task_m = Syskit::TaskContext.new_submodel { output_port "out", stub_t }
                    srv_m = Syskit::DataService.new_submodel { output_port "out", stub_t }
                    dyn_srv = task_m.dynamic_service srv_m, as: "ddd" do
                        provides srv_m, "out" => "does_not_exist"
                    end
                    assert_raises(Syskit::InvalidProvides) { dyn_srv.instanciate("srv") }
                end
            end

            describe "#update_component_model_interface" do
                attr_reader :subject
                before do
                    @subject = flexmock(Syskit::Models::DynamicDataService)
                end

                it "should validate each service port and mapping using #directional_port_mapping and merge" do
                    expected_mappings = Hash["out" => "bla_out", "in" => "bla_in"]

                    subject.should_receive(:directional_port_mapping).with(task_m, "output", srv_m.out_port, "explicit_out")
                           .once.and_return(expected_mappings["out"])
                    subject.should_receive(:directional_port_mapping).with(task_m, "input", srv_m.in_port, nil)
                           .once.and_return(expected_mappings["in"])
                    flexmock(Syskit::Models).should_receive(:merge_orogen_task_context_models)
                                            .with(task_m.orogen_model, [srv_m.orogen_model], expected_mappings)
                                            .once
                    subject.update_component_model_interface(task_m, srv_m, "out" => "explicit_out")
                end
                it "should return the updated port mappings" do
                    expected_mappings = Hash["out" => "bla_out", "in" => "bla_in"]
                    subject.should_receive(:directional_port_mapping).with(task_m, "output", srv_m.out_port, "explicit_out")
                           .once.and_return(expected_mappings["out"])
                    subject.should_receive(:directional_port_mapping).with(task_m, "input", srv_m.in_port, nil)
                           .once.and_return(expected_mappings["in"])
                    flexmock(Syskit::Models).should_receive(:merge_orogen_task_context_models)
                                            .with(task_m.orogen_model, [srv_m.orogen_model], expected_mappings)
                                            .once
                    assert_equal expected_mappings, subject.update_component_model_interface(task_m, srv_m, "out" => "explicit_out")
                end
            end
            describe "#directional_port_mapping" do
                attr_reader :task_m, :port, :context
                before do
                    @task_m = flexmock
                    @port = flexmock(name: "port_name", type: Object.new, type_name: "/bla/type")
                    @context = flexmock(Syskit::Models::DynamicDataService)
                end

                it "should return the expected name if it is an existing component port" do
                    flexmock(task_m).should_receive(:find_bla_port).with("expected_name").and_return(Object.new)
                    assert_equal "expected_name", context.directional_port_mapping(task_m, "bla", port, "expected_name")
                end
                it "should not test whether an existing component port is a valid dynamic port" do
                    flexmock(task_m).should_receive(:find_bla_port).with("expected_name").and_return(Object.new)
                    flexmock(task_m).should_receive("has_dynamic_bla_port?").never
                    context.directional_port_mapping(task_m, "bla", port, "expected_name")
                end
                it "should raise if an implicit mapping is not an existing component port" do
                    flexmock(task_m).should_receive(:find_directional_port_mapping).with("bla", port, nil).and_return(nil)
                    assert_raises(Syskit::InvalidPortMapping) { context.directional_port_mapping(task_m, "bla", port, nil) }
                end
                it "should return the expected name if it validates as an existing dynamic port" do
                    flexmock(task_m).should_receive(:find_bla_port).and_return(nil)
                    flexmock(task_m).should_receive(:has_dynamic_bla_port?).with("expected_name", port.type).and_return(true)
                    assert_equal "expected_name", context.directional_port_mapping(task_m, "bla", port, "expected_name")
                end
                it "should raise if the expected name is neither a static port nor a dynamic one" do
                    flexmock(task_m).should_receive(:find_bla_port).and_return(nil)
                    flexmock(task_m).should_receive(:has_dynamic_bla_port?).with("expected_name", port.type).and_return(false)
                    assert_raises(Syskit::InvalidPortMapping) { context.directional_port_mapping(task_m, "bla", port, "expected_name") }
                end
            end
        end
        describe Syskit::Models::DynamicDataService::InstantiationContext do
            attr_reader :dyn, :context
            before do
                srv_m = self.srv_m
                @dyn = task_m.dynamic_service srv_m, as: "dyn" do
                    provides srv_m, "out" => "#{name}_out", "in" => "#{name}_in"
                end
                @context = Syskit::Models::DynamicDataService::InstantiationContext
                           .new(task_m, "dyn", dyn)
            end
            describe "#provides" do
                it "should call provides_dynamic" do
                    srv_m = self.srv_m.new_submodel
                    flexmock(task_m).should_receive(:provides_dynamic).once
                                    .with(srv_m, Hash["out" => "out_port", "in" => "in_port"], as: "dyn", bound_service_class: Syskit::Models::BoundDynamicDataService)
                                    .and_return(result = flexmock)
                    result.should_receive(:dynamic_service=)
                    result.should_receive(:dynamic_service_options=)
                    context.provides(srv_m, "out" => "out_port", "in" => "in_port")
                end
                it "should set the dynamic service attribute" do
                    bound_srv = context.provides(srv_m, as: "dyn", "out" => "bla_out", "in" => "bla_in")
                    assert_equal dyn, bound_srv.dynamic_service
                end
                it "should raise if the given service model does not match the dynamic service model" do
                    srv_m = Syskit::DataService.new_submodel
                    assert_raises(ArgumentError) { context.provides(srv_m, "out" => "bla_out", "in" => "bla_in") }
                end
                it "should raise if the :as option is given with the wrong name" do
                    assert_raises(ArgumentError) { context.provides(srv_m, as: "bla", "out" => "bla_out", "in" => "bla_in") }
                end
                it "should pass if the :as option is given with the name expected by the instantiation" do
                    context.provides(srv_m, as: "dyn", "out" => "bla_out", "in" => "bla_in")
                end
                it "should raise if #provides has already been called" do
                    context.provides(srv_m, "out" => "bla_out", "in" => "bla_in")
                    assert_raises(ArgumentError) { context.provides(srv_m, "out" => "bla_out", "in" => "bla_in") }
                end
            end
        end
    end

    describe "#bind" do
        attr_reader :component_m
        before do
            @component_m = Syskit::Component.new_submodel(name: "component_m")
        end

        it "returns the object if it fullfills the model" do
            object = flexmock
            object.should_receive(:fullfills?).with(component_m).and_return(true)
            assert_equal object, component_m.bind(object)
        end
        it "raises ArgumentError if the object does not fullfill the model" do
            object = flexmock(to_s: "object")
            object.should_receive(:fullfills?).with(component_m).and_return(false)
            e = assert_raises(ArgumentError) do
                component_m.bind(object)
            end
            assert_equal "cannot bind component_m to object", e.message
        end
        it "is available as 'resolve' for backward compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated).with(/resolve/).once
            object = flexmock
            object.should_receive(:fullfills?).with(component_m).and_return(true)
            assert_equal object, component_m.resolve(object)
        end
    end

    describe "#try_bind" do
        attr_reader :component_m
        before do
            @component_m = Syskit::Component.new_submodel(name: "component_m")
        end

        it "returns the object if it fullfills the model" do
            object = flexmock
            object.should_receive(:fullfills?).with(component_m).and_return(true)
            assert_equal object, component_m.try_bind(object)
        end
        it "returns nil if the object does not fullfill the model" do
            object = flexmock(to_s: "object")
            object.should_receive(:fullfills?).with(component_m).and_return(false)
            refute component_m.try_bind(object)
        end
        it "is available as 'try_resolve' for backward compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated).with(/try_resolve/).once
            object = flexmock
            object.should_receive(:fullfills?).with(component_m).and_return(false)
            refute component_m.try_resolve(object)
        end
    end

    describe "#self_port_to_component_port" do
        it "should return its argument" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel { output_port "out", stub_t }
            assert_equal task_m.out_port, task_m.self_port_to_component_port(task_m.out_port)
        end
    end

    describe "#find_all_data_services_from_type" do
        it "should return an empty set if there are no matches" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            assert(component.find_all_data_services_from_type(service).empty?)
        end

        it "should return the set of matching services" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel

            bound_services = Set.new
            bound_services << component.provides(service, as: "image")
            assert_equal(bound_services,
                         component.find_all_data_services_from_type(service).to_set)
            bound_services << component.provides(service, as: "camera")
            assert_equal(bound_services,
                         component.find_all_data_services_from_type(service).to_set)
        end

        it "should return services faceted to the required model when the bound data service is a subtype of the required one" do
            srv_m = Syskit::DataService.new_submodel
            sub_srv_m = Syskit::DataService.new_submodel
            sub_srv_m.provides srv_m
            cmp_m = Syskit::Component.new_submodel
            cmp_m.provides sub_srv_m, as: "test"

            assert_equal [cmp_m.test_srv.as(srv_m)], cmp_m.find_all_data_services_from_type(srv_m)
        end
    end

    describe "#each_dynamic_service" do
        it "should yield nothing for plain models" do
            task_m = Syskit::TaskContext.new_submodel
            srv_m = Syskit::DataService.new_submodel
            task_m.provides srv_m, as: "test"
            task_m.each_required_dynamic_service.empty?
        end

        it "should yield services instanciated through the dynamic service mechanism" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            dyn_srv_m = task_m.dynamic_service srv_m, as: "dyn" do
                provides srv_m, as: name
            end
            task_m.each_required_dynamic_service.empty?

            model_m = task_m.new_submodel
            dyn_srv = model_m.require_dynamic_service "dyn", as: "test"
            assert_equal [dyn_srv], model_m.each_required_dynamic_service.to_a
        end
    end

    describe "#fullfills?" do
        describe "handling of specialized models" do
            before do
                @srv_m = srv_m = Syskit::DataService.new_submodel
                @task_m = Syskit::TaskContext.new_submodel do
                    dynamic_service srv_m, as: "test" do
                        provides srv_m
                    end
                end
            end

            it "returns false if the argument has required dynamic services that the receiver does not" do
                argument_m = @task_m.specialize
                argument_m.require_dynamic_service "test", as: "test"
                receiver_m = @task_m.specialize
                refute receiver_m.fullfills?(argument_m)
            end
            it "returns true if the receiver has all the required dynamic services of the argument" do
                argument_m = @task_m.specialize
                argument_m.require_dynamic_service "test", as: "test"
                receiver_m = @task_m.specialize
                receiver_m.require_dynamic_service "test", as: "test"
                assert receiver_m.fullfills?(argument_m)
            end
            it "returns true if the receiver has required dynamic services that the argument does not have" do
                argument_m = @task_m.specialize
                receiver_m = @task_m.specialize
                receiver_m.require_dynamic_service "test", as: "test"
                assert receiver_m.fullfills?(argument_m)
            end
            it "returns true if the argument is the concrete model" do
                receiver_m = @task_m.specialize
                receiver_m.require_dynamic_service "test", as: "test"
                assert receiver_m.fullfills?(@task_m)
            end
        end
    end

    describe "#merge" do
        it "should return the most-derived model" do
            m0 = Syskit::Component.new_submodel
            m1 = m0.new_submodel
            assert_equal m1, m0.merge(m1)
            assert_equal m1, m1.merge(m0)
        end

        it "should raise IncompatibleComponentModels if the two models are incompatible" do
            m0 = Syskit::Component.new_submodel
            m1 = Syskit::Component.new_submodel
            assert_raises(Syskit::IncompatibleComponentModels) { m0.merge(m1) }
        end

        describe "in presence of specialized models and dynamic services" do
            attr_reader :base_m, :srv_m, :m0, :m1

            before do
                @base_m = Syskit::TaskContext.new_submodel
                @srv_m = srv_m = Syskit::DataService.new_submodel
                base_m.dynamic_service srv_m, as: "test" do
                    provides srv_m
                end
                @m0 = base_m.specialize
                m0.require_dynamic_service "test", as: "m0"
                @m1 = base_m.specialize
                m1.require_dynamic_service "test", as: "m1"
            end

            it "should return a new specialization" do
                result = m0.merge(m1)
                assert result.private_specialization?
                refute_equal result, m0
                refute_equal result, m1
            end

            it "should instanciate the dynamic services of both sides" do
                result = m0.merge(m1)
                assert result.m0_srv
                assert result.m1_srv
            end

            it "should specialize the base model only once" do
                result = m0.merge(m1)
                assert_equal base_m, result.superclass
            end

            it "should be a specialization of the most-specific model" do
                m1_base_m = base_m.new_submodel
                m1 = m1_base_m.specialize
                result = m0.merge(m1)
                assert_equal m1_base_m, result.superclass
            end
        end
    end

    describe "#fullfilled_model" do
        it "does not return itself it it is a private specialization" do
            task_m = Syskit::Component.new_submodel
            specialized_m = task_m.specialize
            assert !specialized_m.fullfilled_model.include?(specialized_m)
        end
    end

    describe "#provides" do
        it "passes Roby task services to super" do
            task_service_m = Roby::TaskService.new_submodel
            component_m = Syskit::Component.new_submodel
            component_m.provides task_service_m
            assert component_m.fullfills?(task_service_m)
        end
        it "raises if no service name is given" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            assert_raises(ArgumentError) { component.provides(service) }
        end

        it "registers the service under the specified name" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            bound_service = component.provides service, as: "camera"
            assert_equal bound_service, component.find_data_service("camera")
        end

        it "refuses to add a service with under a name already existing at this level of the component model hierarchy" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            component.provides service, as: "srv"
            assert_raises(ArgumentError) { component.provides(service, as: "srv") }
        end

        it "allows to override a parent service" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            component.provides service, as: "srv"
            submodel = component.new_submodel
            submodel.provides service, as: "srv"
        end

        it "validates that an overriden service is extending the model of the parent service" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            component.provides service, as: "srv"

            other_service = Syskit::DataService.new_submodel
            submodel = component.new_submodel
            assert_raises(ArgumentError) { submodel.provides other_service, as: "srv" }
        end

        it "defines slave services" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            root_srv = component.provides service, as: "root"
            slave_srv = component.provides service, as: "srv", slave_of: "root"
            assert_equal [slave_srv], root_srv.each_slave_data_service.to_a
            assert_same slave_srv, component.find_data_service("root.srv")
            assert_equal "srv", slave_srv.name
            assert_equal "root.srv", slave_srv.full_name
        end

        it "allows slave services to have the same name than a root service" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            root_srv = component.provides service, as: "root"
            srv = component.provides service, as: "srv"
            root_srv = component.provides service, as: "srv", slave_of: "root"
            assert_same srv, component.find_data_service("srv")
            assert_same root_srv, component.find_data_service("root.srv")
        end

        describe "the port mapping computation" do
            attr_reader :service
            before do
                stub_t = self.stub_t
                @service = Syskit::DataService.new_submodel { output_port "out", stub_t }
            end

            it "selects port mappings based on type first" do
                stub_t = self.stub_t
                other_stub_t = self.other_stub_t
                component = Syskit::TaskContext.new_submodel do
                    output_port "out", other_stub_t
                    output_port "other", stub_t
                end
                bound_service = component.provides service, as: "srv"
                assert_equal({ "out" => "other" }, bound_service.port_mappings_for_task)
            end

            it "raises if the component does not provide equivalents to the service's ports" do
                # No matching port
                component = Syskit::TaskContext.new_submodel
                assert_raises(Syskit::InvalidProvides) { component.provides(service, as: "srv") }
                assert(!component.find_data_service_from_type(service))
            end

            it "raises if the component has a port matching on name and type, but with the wrong direction" do
                # Wrong port direction
                stub_t = self.stub_t
                component = Syskit::TaskContext.new_submodel do
                    input_port "out", stub_t
                end
                assert_raises(Syskit::InvalidProvides) { component.provides(service, as: "srv") }
                assert(!component.find_data_service_from_type(service))
            end

            it "raises if there is an ambiguity on port types and no matching name exists" do
                stub_t = self.stub_t
                # Ambiguous type mapping, no exact match on the name
                component = Syskit::TaskContext.new_submodel do
                    output_port "other1", stub_t
                    output_port "other2", stub_t
                end
                assert_raises(Syskit::InvalidProvides) do
                    component.provides(service, as: "srv")
                end
                assert(!component.find_data_service_from_type(service))
            end

            it "disambiguates on the port direction" do
                stub_t = self.stub_t
                # Ambiguous type mapping, one of the two possibilites has the wrong
                # direction
                component = Syskit::TaskContext.new_submodel do
                    input_port "other1", stub_t
                    output_port "other2", stub_t
                end
                bound_service = component.provides(service, as: "srv")
                assert_equal({ "out" => "other2" }, bound_service.port_mappings_for_task)
            end

            it "disambiguates on the port name" do
                stub_t = self.stub_t
                # Ambiguous type mapping, exact match on the name
                component = Syskit::TaskContext.new_submodel do
                    output_port "out", stub_t
                    output_port "other2", stub_t
                end
                bound_service = component.provides(service, as: "srv")
                assert_equal({ "out" => "out" }, bound_service.port_mappings_for_task)
            end

            it "disambiguates on explicitely given port mappings" do
                stub_t = self.stub_t
                component = Syskit::TaskContext.new_submodel do
                    output_port "other1", stub_t
                    output_port "other2", stub_t
                end
                bound_service = component.provides(
                    service, { "out" => "other1" }, as: "srv"
                )
                assert_equal({ "out" => "other1" }, bound_service.port_mappings_for_task)
            end

            it "raises if given an explicit port mapping with an invalid service port" do
                stub_t = self.stub_t
                component = Syskit::TaskContext.new_submodel do
                    output_port "out", stub_t
                end
                assert_raises(Syskit::InvalidProvides) do
                    component.provides(
                        service, { "does_not_exist" => "other1" }, as: "srv"
                    )
                end
            end

            it "raises if given an explicit port mapping "\
               "with an invalid component port" do
                stub_t = self.stub_t
                component = Syskit::TaskContext.new_submodel do
                    output_port "out", stub_t
                end
                assert_raises(Syskit::InvalidProvides) do
                    component.provides(service, { "out" => "does_not_exist" }, as: "srv")
                end
            end
        end
    end

    describe "#new_submodel" do
        it "registers the submodel in #new_submodel" do
            submodel = Syskit::Component.new_submodel
            subsubmodel = submodel.new_submodel

            assert Syskit::Component.has_submodel?(submodel)
            assert Syskit::Component.has_submodel?(subsubmodel)
            assert submodel.has_submodel?(subsubmodel)
        end

        it "clears the registered submodels on #clear_submodels" do
            root = Syskit::Component.new_submodel
            m1 = root.new_submodel
            m2 = root.new_submodel
            m11 = m1.new_submodel

            m1.clear_submodels
            assert !m1.has_submodel?(m11)
            assert root.has_submodel?(m1)
            assert root.has_submodel?(m2)
            assert !root.has_submodel?(m11)

            m11 = m1.new_submodel
            root.clear_submodels
            assert !m1.has_submodel?(m11)
            assert !root.has_submodel?(m1)
            assert !root.has_submodel?(m2)
            assert !root.has_submodel?(m11)
        end

        it "can provide a name to anonymous models" do
            assert_equal "C", Syskit::Component.new_submodel(name: "C").name
        end
    end

    describe "#short_name" do
        it "returns the model name if there is one" do
            assert_equal "C", Syskit::Component.new_submodel(name: "C").short_name
        end

        it "returns #to_s if the model has no name" do
            m = Syskit::Component.new_submodel
            flexmock(m).should_receive(:to_s).and_return("my_name").once
            assert_equal "my_name", m.short_name
        end
    end

    describe "#find_data_service" do
        it "returns nil if the service is unknown" do
            stub_t = self.stub_t
            component = Syskit::TaskContext.new_submodel do
                output_port "out", stub_t
            end
            assert_nil component.find_data_service("does_not_exist")
        end
        it "returns a data service object bound to the actual model" do
            s = Syskit::DataService.new_submodel
            c = Syskit::TaskContext.new_submodel { provides s, as: "srv" }
            sub_c = c.new_submodel
            assert_equal sub_c, sub_c.find_data_service("srv").component_model
        end
    end

    describe "#find_data_service_from_type" do
        attr_reader :service, :component
        before do
            @service   = Syskit::DataService.new_submodel
            @component = Syskit::Component.new_submodel
        end
        it "returns nil if no service with that type exists" do
            assert_nil component.find_data_service_from_type(service)
        end
        it "returns a unique service matching the service model" do
            bound_service = component.provides service, as: "image"
            assert_equal bound_service, component.find_data_service_from_type(service)
        end
        it "raises AmbiguousServiceSelection if more than one service exists with the requested type" do
            component.provides service, as: "image"
            component.provides service, as: "camera"
            assert_raises(Syskit::AmbiguousServiceSelection) do
                component.find_data_service_from_type(service)
            end
        end
        it "returns a data service bound to the actual component model" do
            s = Syskit::DataService.new_submodel
            c = Syskit::TaskContext.new_submodel { provides s, as: "srv" }
            sub_c = c.new_submodel
            assert_equal sub_c, sub_c.find_data_service_from_type(s).component_model
        end
    end

    describe "#each_slave_data_service" do
        it "enumerates the slaves of a given service" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            root = component.provides service, as: "root"
            slave = component.provides service, as: "srv", slave_of: "root"
            assert_equal [slave].to_set, component.each_slave_data_service(root).to_set
        end

        it "promotes the bound services to a submodel's" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            root = component.provides service, as: "root"
            slave = component.provides service, as: "srv", slave_of: "root"
            component = component.new_submodel
            assert_equal [slave.attach(component)], component.each_slave_data_service(root).to_a
        end

        it "enumerates both its own slave services and its parent's" do
            service = Syskit::DataService.new_submodel
            component = Syskit::TaskContext.new_submodel
            root = component.provides service, as: "root"
            slave1 = component.provides service, as: "srv1", slave_of: "root"
            component = component.new_submodel
            slave2 = component.provides service, as: "srv2", slave_of: "root"
            assert_equal [slave1.attach(component), slave2].to_a, component.each_slave_data_service(root).sort_by(&:full_name)
        end
    end

    describe "#has_input_port?" do
        attr_reader :component_m
        before do
            @component_m = Syskit::TaskContext.new_submodel
            flexmock(component_m)
        end
        it "returns falsy if the port cannot be found" do
            component_m.should_receive(:find_input_port).with("p").and_return(nil)
            refute component_m.has_input_port?("p")
        end
        it "returns truthy if the port can be found" do
            component_m.should_receive(:find_input_port).with("p").and_return(Object.new)
            assert component_m.has_input_port?("p")
        end
    end

    describe "#has_output_port?" do
        attr_reader :component_m
        before do
            @component_m = Syskit::TaskContext.new_submodel
            flexmock(component_m)
        end
        it "returns falsy if the port cannot be found" do
            component_m.should_receive(:find_output_port).with("p").and_return(nil)
            refute component_m.has_output_port?("p")
        end
        it "returns truthy if the port can be found" do
            component_m.should_receive(:find_output_port).with("p").and_return(Object.new)
            assert component_m.has_output_port?("p")
        end
    end

    describe "#find_input_port" do
        it "finds a port by its name" do
            stub_t = self.stub_t
            port_model = nil
            model = Syskit::TaskContext.new_submodel do
                port_model = input_port("p", stub_t)
            end
            assert(p = model.find_input_port("p"))
            assert_equal "p", p.name, "p"
            assert_equal model, p.component_model
            assert_equal port_model, p.orogen_model
        end
        it "returns falsey if the port's direction does not match" do
            stub_t = self.stub_t
            model = Syskit::TaskContext.new_submodel do
                output_port("p", stub_t)
            end
            refute model.find_input_port("p")
        end
        it "returns nil on non-existent ports" do
            model = Syskit::TaskContext.new_submodel
            assert_nil model.find_input_port("does_not_exist")
        end
    end

    describe "#find_output_port" do
        attr_reader :model, :port_model
        before do
        end
        it "finds a port by its name" do
            stub_t = self.stub_t
            port_model = nil
            model = Syskit::TaskContext.new_submodel do
                port_model = output_port("p", stub_t)
            end
            assert(p = model.find_output_port("p"))
            assert_equal "p", p.name, "p"
            assert_equal model, p.component_model
            assert_equal port_model, p.orogen_model
        end
        it "returns falsey if the port's direction does not match" do
            stub_t = self.stub_t
            model = Syskit::TaskContext.new_submodel do
                input_port("p", stub_t)
            end
            refute model.find_output_port("p")
        end
        it "returns nil on non-existent ports" do
            model = Syskit::TaskContext.new_submodel
            assert_nil model.find_output_port("does_not_exist")
        end
    end

    describe "#create_proxy_task" do
        it "creates an abstract task of the same model" do
            c = Syskit::Component.new_submodel
            task = c.create_proxy_task
            assert_kind_of c, task
            assert task.abstract?
        end
    end

    describe "#driver_for" do
        before do
            @dev_m = Syskit::Device.new_submodel
        end

        it "provides the device service model" do
            task_m = Syskit::Component.new_submodel
            task_m.driver_for @dev_m, as: "test"
            assert task_m.test_srv, task_m.find_data_service_from_type(@dev_m)
        end

        it "creates the device argument" do
            task_m = Syskit::Component.new_submodel
            task_m.driver_for @dev_m, as: "test"
            assert task_m.has_argument?(:test_dev)
        end

        it "forwards port mapping arguments" do
            dev_m = Syskit::Device.new_submodel do
                input_port "in", "/double"
                output_port "out", "/double"
            end

            task_m = Syskit::TaskContext.new_submodel do
                input_port "in1", "/double"
                input_port "in2", "/double"
                output_port "out1", "/double"
                output_port "out2", "/double"
            end

            task_m.driver_for dev_m, "in" => "in2", "out" => "out1", as: "test"
            assert_equal task_m.in2_port, task_m.test_srv.in_port.to_component_port
            assert_equal task_m.out1_port, task_m.test_srv.out_port.to_component_port
        end
    end
end
