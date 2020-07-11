# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Test_DataServiceModel
        attr_reader :service_type
        attr_reader :dsl_service_type_name

        DataServiceModel = Syskit::Models::DataServiceModel

        def teardown
            super
            begin DataServiceDefinitionTest.send(:remove_const, :Image)
            rescue NameError
            end
        end

        def new_submodel(*args, **options, &block)
            service_type.new_submodel(*args, **options, &block)
        end

        def test_data_services_are_registered_as_submodels_of_task_service
            srv = DataService.new_submodel
            assert Roby::TaskService.each_submodel.to_a.include?(srv)
        end

        def test_new_submodel_can_give_name_to_anonymous_models
            assert_equal "Srv", new_submodel(name: "Srv").name
        end

        def test_short_name_returns_name_if_there_is_one
            assert_equal "Srv", new_submodel(name: "Srv").short_name
        end

        def test_short_name_returns_to_s_if_there_are_no_name
            m = new_submodel
            flexmock(m).should_receive(:to_s).and_return("my_name").once
            assert_equal "my_name", m.short_name
        end

        def test_new_submodel_without_name
            model = new_submodel
            assert_kind_of(DataServiceModel, model)
            assert(model < service_type)
            assert(!model.name)
        end

        def test_new_submodel_with_name
            model = new_submodel(name: "Image")
            assert_kind_of(DataServiceModel, model)
            assert(model < service_type)
            assert_equal("Image", model.name)
        end

        module DataServiceDefinitionTest
        end

        def test_module_dsl_service_type_definition_requires_valid_name
            assert_raises(ArgumentError) { DataServiceDefinitionTest.send(dsl_service_type_name, "Srv::Image") }
            assert_raises(ArgumentError) { DataServiceDefinitionTest.send(dsl_service_type_name, "image") }
        end

        def test_placeholder_model
            model = new_submodel
            placeholder_model = model.placeholder_model
            assert(placeholder_model <= Component)
            assert(placeholder_model.fullfills?(model))
            assert_equal([model], placeholder_model.proxied_data_service_models.to_a)
        end

        def test_placeholder_model_caches_model
            model = new_submodel
            placeholder_model = model.placeholder_model
            assert_same placeholder_model, model.placeholder_model
        end

        def test_model_output_port
            model = new_submodel do
                input_port "in", "double"
                output_port "out", "int32_t"
            end
            assert_equal("/int32_t", model.find_output_port("out").type.name)
            assert_nil model.find_output_port("does_not_exist")
            assert_nil model.find_output_port("in")
        end

        def test_model_input_port
            model = new_submodel do
                input_port "in", "double"
                output_port "out", "int32_t"
            end
            assert_equal("/double", model.find_input_port("in").type.name)
            assert_nil model.find_input_port("out")
            assert_nil model.find_input_port("does_not_exist")
        end

        def test_provides
            parent_model = new_submodel
            model = new_submodel
            model.provides parent_model
            assert(model.fullfills?(parent_model))
            assert(model.parent_models.include?(parent_model))
        end

        def test_provides_ports
            parent_model = new_submodel do
                output_port "out", "/int"
            end
            model = new_submodel
            model.provides parent_model
            assert(model.find_output_port("out"))
            assert(model.fullfills?(parent_model))

            assert_equal({ "out" => "out" }, model.port_mappings_for(parent_model))
            assert_equal({ "out" => "out" },
                         model.port_mappings_for(model))
        end

        def test_provides_port_mappings_for_is_transitive
            base = new_submodel do
                output_port "base", "/int"
                output_port "base_unmapped", "/double"
            end
            parent = new_submodel do
                output_port "parent", "/int"
                output_port "parent_unmapped", "/double"
            end
            parent.provides base, "base" => "parent"
            model = new_submodel do
                output_port "model", "/int"
            end
            model.provides parent, "parent" => "model"

            assert_equal({ "parent" => "model",
                           "base_unmapped" => "base_unmapped",
                           "parent_unmapped" => "parent_unmapped" }, model.port_mappings_for(parent))
            assert_equal({ "base" => "model",
                           "base_unmapped" => "base_unmapped" }, model.port_mappings_for(base))
        end

        def test_provides_detects_port_collisions_even_if_they_have_the_same_type
            base_m = new_submodel do
                output_port "out", "/double"
            end
            provided_m = new_submodel do
                output_port "out", "/double"
            end

            assert_raises(Syskit::SpecError) { base_m.provides provided_m }
        end

        def test_provides_port_collision_with_different_types
            parent_model = new_submodel do
                output_port "out", "/int"
            end

            model = new_submodel do
                output_port "out", "/double"
            end
            assert_raises(Syskit::SpecError) { model.provides parent_model }

            model = new_submodel do
                output_port "out", "/double"
            end
            assert_raises(Syskit::SpecError) { model.provides parent_model }

            model = new_submodel do
                input_port "out", "/int"
            end
            assert_raises(Syskit::SpecError) { model.provides parent_model }
        end

        def test_provides_with_port_mappings
            parent_model = new_submodel do
                output_port "out", "/int"
            end
            model = new_submodel do
                output_port "new_out", "/int"
            end
            model.provides parent_model, "out" => "new_out"
            assert(!model.find_output_port("out"))
            assert(model.find_output_port("new_out"))
            assert(model.fullfills?(parent_model))

            assert_equal({ "out" => "new_out" }, model.port_mappings_for(parent_model))
            assert_equal({ "new_out" => "new_out" },
                         model.port_mappings_for(model))
        end

        def test_provides_port_mapping_validation
            parent_model = new_submodel do
                output_port "out", "/int"
            end

            model = new_submodel do
                output_port "new_out", "/double"
            end
            assert_raises(Syskit::SpecError) { model.provides(parent_model, "out" => "new_out") }
            assert_raises(Syskit::SpecError) { model.provides(parent_model, "out" => "really_new_out") }
            assert_raises(Syskit::SpecError) { model.provides(parent_model, "old_out" => "new_out") }

            model = new_submodel do
                output_port "new_out", "/double"
            end
            assert_raises(Syskit::SpecError) { model.provides(parent_model, "out" => "new_out") }

            model = new_submodel do
                input_port "new_out", "/int"
            end
            assert_raises(Syskit::SpecError) { model.provides(parent_model, "out" => "new_out") }
        end

        def test_provides_can_override_port_using_port_mappings
            parent_model = new_submodel do
                output_port "out", "/int32_t"
            end

            model = new_submodel do
                output_port "out", "/double"
                output_port "new_out", "/int32_t"
            end
            model.provides(parent_model, "out" => "new_out")

            assert_equal("/double", model.find_output_port("out").type_name)
            assert_equal("/int32_t", model.find_output_port("new_out").type_name)

            assert_equal({ "out" => "new_out" }, model.port_mappings_for(parent_model))
            assert_equal({ "out" => "out", "new_out" => "new_out" },
                         model.port_mappings_for(model))
        end

        def test_create_placeholder_task
            model = new_submodel(name: "A")
            task = model.create_placeholder_task
            assert task.abstract?
            assert_kind_of model.placeholder_model, task
        end

        def test_instanciate
            model = new_submodel(name: "A")
            task = model.instanciate(plan)
            assert_kind_of model.placeholder_model, task
        end

        def test_it_can_be_droby_marshalled_and_unmarshalled
            model = new_submodel(name: "A")
            loaded = Marshal.load(Marshal.dump(model.droby_dump(Roby::DRoby::Marshal.new)))
            loaded = loaded.proxy(Roby::DRoby::Marshal.new)
            assert(loaded <= service_type)
            assert_equal model.name, loaded.name
        end
    end

    describe DataService do
        include Test_DataServiceModel

        before do
            @service_type = DataService
            @dsl_service_type_name = :data_service_type
        end

        describe "the DSL definition" do
            attr_reader :mod
            before do
                @mod = Module.new
            end

            it "registers the services as constant on the receiver" do
                srv = mod.data_service_type "Image"
                assert_same srv, mod::Image
            end
        end

        describe "#provides" do
            it "refuses to provide a ComBus" do
                srv = DataService.new_submodel
                combus = ComBus.new_submodel message_type: "/int"
                assert_raises(ArgumentError) { srv.provides combus }
            end
            it "refuses to provide a Device" do
                srv = DataService.new_submodel
                device = Device.new_submodel
                assert_raises(ArgumentError) { srv.provides device }
            end
        end

        describe "#each_fullfilled_model" do
            it "includes the model itself, the service type and the root models" do
                parent_model = DataService.new_submodel
                assert_equal [parent_model, DataService],
                             parent_model.each_fullfilled_model.to_a
            end
            it "includes other service models it provides" do
                parent_model = DataService.new_submodel
                child_model  = DataService.new_submodel { provides parent_model }
                assert_equal [child_model, parent_model, DataService],
                             child_model.each_fullfilled_model.to_a
            end
        end

        describe "#try_bind" do
            before do
                @srv_m = DataService.new_submodel
                @task_m = Component.new_submodel
            end
            it "returns a non-ambiguous bound service if there is one" do
                @task_m.provides @srv_m, as: "test"
                plan.add(task = @task_m.new)
                assert_equal task.test_srv, @srv_m.try_bind(task)
            end
            it "returns nil on ambiguities" do
                @task_m.provides @srv_m, as: "test1"
                @task_m.provides @srv_m, as: "test2"
                plan.add(task = @task_m.new)
                assert_nil @srv_m.try_bind(task)
            end
            it "returns nil if no service matches" do
                plan.add(task = @task_m.new)
                assert_nil @srv_m.try_bind(task)
            end
            it "is available as #try_resolve for backward compatibility" do
                flexmock(Roby).should_receive(:warn_deprecated).with(/try_resolve/).once
                @task_m.provides @srv_m, as: "test"
                plan.add(task = @task_m.new)
                assert_equal task.test_srv, @srv_m.try_resolve(task)
            end
        end

        describe "#bind" do
            it "returns the value of try_bind is non-nil" do
                srv_m = DataService.new_submodel
                flexmock(srv_m).should_receive(:try_bind).with(task = flexmock).and_return(obj = flexmock)
                assert_equal obj, srv_m.bind(task)
            end

            it "raises if try_bind returns nil" do
                srv_m = DataService.new_submodel
                flexmock(srv_m).should_receive(:try_bind).with(task = flexmock).and_return(nil)
                assert_raises(ArgumentError) do
                    srv_m.bind(task)
                end
            end
        end

        describe "#resolve" do
            it "is an old name for #bind" do
                flexmock(Roby).should_receive(:warn_deprecated).with(/resolve/).once
                srv_m = DataService.new_submodel
                flexmock(srv_m).should_receive(:bind).with(task = flexmock).and_return(obj = flexmock)
                assert_equal obj, srv_m.resolve(task)
            end
        end

        describe "Port#connected?" do
            it "returns false" do
                m0 = DataService.new_submodel do
                    output_port "out", "int"
                end
                m1 = DataService.new_submodel do
                    input_port "in", "int"
                end
                assert !m0.out_port.connected_to?(m1.in_port)
            end
        end
    end

    describe Device do
        include Test_DataServiceModel

        before do
            @service_type = Device
            @dsl_service_type_name = :device_type
        end

        describe "the DSL definition" do
            attr_reader :mod
            before do
                @mod = Module.new
            end

            it "registers the services as constant on the receiver" do
                srv = mod.device_type "Image"
                assert_same srv, mod::Image
            end
        end

        describe "#provides" do
            it "does not change #supermodel" do
                srv = Device.new_submodel
                assert_equal Device, srv.supermodel
                srv.provides DataService.new_submodel
                assert_equal Device, srv.supermodel
            end

            it "refuses to provide a ComBus" do
                srv = Device.new_submodel
                combus = ComBus.new_submodel message_type: "/int"
                assert_raises(ArgumentError) { srv.provides combus }
            end
        end

        describe "#each_fullfilled_model" do
            it "includes the model itself, the service type and the root models" do
                parent_model = Device.new_submodel
                assert_equal [parent_model, Device, DataService],
                             parent_model.each_fullfilled_model.to_a
            end
            it "includes other service models it provides" do
                parent_model = Device.new_submodel
                child_model  = Device.new_submodel { provides parent_model }
                assert_equal [child_model, parent_model, Device, DataService],
                             child_model.each_fullfilled_model.to_a
            end
        end

        describe "#find_all_drivers" do
            it "returns the list of task contexts declared as drivers for self" do
                device = Device.new_submodel
                task0 = TaskContext.new_submodel { driver_for device, as: "driver" }
                task1 = TaskContext.new_submodel { driver_for device, as: "driver" }
                assert_equal [task0, task1].to_set, device.find_all_drivers.to_set
            end
        end

        describe "#default_driver" do
            subject { Device.new_submodel }

            it "raises Ambiguous if more than one driver exists" do
                flexmock(subject).should_receive(:find_all_drivers).and_return([2, 1])
                assert_raises(Ambiguous) { subject.default_driver }
            end
            it "raises ArgumentError if there are no drivers" do
                assert_raises(ArgumentError) { subject.default_driver }
            end
            it "returns the driver if there is exactly one" do
                flexmock(subject).should_receive(:find_all_drivers)
                                 .and_return([mock = flexmock])
                assert_equal mock, subject.default_driver
            end
        end
    end

    describe ComBus do
        include Test_DataServiceModel

        def new_submodel(name: nil, message_type: "/int", &block)
            ComBus.new_submodel(name: name, message_type: message_type, &block)
        end

        before do
            # This is defined for the benefit of Test_DataServiceModel
            @service_type = ComBus
            @dsl_service_type_name = :com_bus_type
        end

        # This is important for reloading: the reloading code calls
        # ExistingComBusModule.provides ComBus
        it "can provide ComBus" do
            m = new_submodel
            m.clear_model
            m.provides ComBus
        end

        it "is registered as a submodel of Roby::TaskService" do
            combus = ComBus.new_submodel message_type: "/int"
            assert Roby::TaskService.each_submodel.to_a.include?(combus)
        end

        it "declares the necesary dynamic service when provided on its driver" do
            combus = ComBus.new_submodel message_type: "/int"
            driver_m = TaskContext.new_submodel
            flexmock(combus).should_receive(:dynamic_service_name).and_return("dyn_srv")
            flexmock(driver_m).should_receive(:dynamic_service).with(combus.bus_base_srv, Hash[as: "dyn_srv"], Proc).once
            driver_m.provides combus, as: "name"
        end

        describe "the dynamic service definition" do
            attr_reader :combus_m, :driver_m
            before do
                @combus_m = ComBus.new_submodel message_type: "/double"
                @driver_m = TaskContext.new_submodel do
                    dynamic_input_port(/\w+/, "/double")
                    dynamic_output_port(/\w+/, "/double")
                end
                flexmock(combus_m).should_receive(:dynamic_service_name).and_return("dyn_srv")
                driver_m.driver_for combus_m, as: "combus_driver"
            end
            it "instanciates an input bus service if requested one" do
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: false, client_to_bus: true
                )
                assert_same combus_m.bus_in_srv, srv.model.model
            end
            it "uses a static input service if one is available" do
                combus_m = @combus_m
                driver_m = TaskContext.new_submodel do
                    input_port "driver_in", "/double"
                    provides combus_m::BusInSrv, as: "bus_in"
                end
                driver_m.driver_for combus_m, as: "combus_driver"

                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: false, client_to_bus: true
                )

                in_port_m = srv.to_bus_port.to_component_port.model

                assert_equal driver_m, in_port_m.component_model.superclass
                assert_equal "driver_in", in_port_m.name
            end
            it "provides the mapping of from_bus to input_name_for if requested an input service" do
                flexmock(combus_m).should_receive(:input_name_for)
                                  .with("dev").and_return("in_DEV")
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: false, client_to_bus: true
                )
                assert_equal Hash["to_bus" => "in_DEV"], srv.model.port_mappings_for_task
            end
            it "instanciates an output bus service if requested one" do
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: true, client_to_bus: false
                )
                assert_same combus_m.bus_out_srv, srv.model.model
            end
            it "provides the mapping of from_bus to output_name_for if requested an output service" do
                flexmock(combus_m).should_receive(:output_name_for).with("dev")
                                  .and_return("out_DEV")
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: true, client_to_bus: false
                )
                assert_equal Hash["from_bus" => "out_DEV"], srv.model.port_mappings_for_task
            end
            it "instanciates bidirectional service if requested one" do
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: true, client_to_bus: true
                )
                assert_same combus_m.bus_srv, srv.model.model
            end
            it "provides the proper mappings if requested a bidirectional service" do
                flexmock(combus_m).should_receive(:output_name_for)
                                  .with("dev").and_return("out_DEV")
                flexmock(combus_m).should_receive(:input_name_for)
                                  .with("dev").and_return("in_DEV")
                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: true, client_to_bus: true
                )
                assert_equal Hash["from_bus" => "out_DEV", "to_bus" => "in_DEV"],
                             srv.model.port_mappings_for_task
            end
            it "uses a static output service if one is available" do
                combus_m = @combus_m
                driver_m = TaskContext.new_submodel do
                    output_port "driver_out", "/double"
                    provides combus_m::BusOutSrv, as: "bus_out"
                end
                driver_m.driver_for combus_m, as: "combus_driver"

                srv = driver_m.new.require_dynamic_service(
                    "dyn_srv", as: "dev", bus_to_client: true, client_to_bus: false
                )

                out_port_m = srv.from_bus_port.to_component_port.model

                assert_equal driver_m, out_port_m.component_model.superclass
                assert_equal "driver_out", out_port_m.name
            end
            it "raises if the bus_to_client option is not provided" do
                assert_raises(ArgumentError) do
                    driver_m.new.require_dynamic_service(
                        "dyn_srv", as: "dev", client_to_bus: true
                    )
                end
            end
            it "raises if the client_to_bus option is not provided" do
                assert_raises(ArgumentError) do
                    driver_m.new.require_dynamic_service(
                        "dyn_srv", as: "dev", bus_to_client: true
                    )
                end
            end
            it "raises if both bus_to_client and client_to_bus options are false" do
                assert_raises(ArgumentError) do
                    driver_m.new.require_dynamic_service(
                        "dyn_srv", as: "dev", bus_to_client: false, client_to_bus: false
                    )
                end
            end
        end

        describe "#extend_attached_device_configuration" do
            it "can be called from within the definition block" do
                com_bus = ComBus.new_submodel message_type: "/double" do
                    extend_attached_device_configuration do
                        def m; end
                    end
                end
                assert com_bus.attached_device_configuration_module
                              .instance_methods.include?(:m)
            end
        end

        describe "#each_fullfilled_model" do
            it "includes the model itself, the service type and the root models" do
                parent_model = ComBus.new_submodel message_type: "/int"
                assert_equal [parent_model, ComBus, Device, DataService],
                             parent_model.each_fullfilled_model.to_a
            end
            it "includes other service models it provides" do
                parent_model = ComBus.new_submodel message_type: "/int"
                child_model  = ComBus.new_submodel { provides parent_model }
                assert_equal [child_model, parent_model, ComBus, Device, DataService],
                             child_model.each_fullfilled_model.to_a
            end
        end

        describe "#provides" do
            it "does not change #supermodel when given a data service" do
                srv = ComBus.new_submodel message_type: "/int"
                assert_equal ComBus, srv.supermodel
                srv.provides DataService.new_submodel
                assert_equal ComBus, srv.supermodel
            end

            it "does not change #supermodel when given a device" do
                srv = ComBus.new_submodel message_type: "/int"
                assert_equal ComBus, srv.supermodel
                srv.provides Device.new_submodel
                assert_equal ComBus, srv.supermodel
            end
        end

        describe "#new_submodel" do
            attr_reader :combus
            before do
                @test_t  = stub_type "/test_t"
                @other_t = stub_type "/other_t"
                @combus = ComBus.new_submodel message_type: "/test_t"
            end

            it "can set the message type directly" do
                combus = ComBus.new_submodel message_type: "/test_t"
                assert_equal @test_t, combus.message_type
            end

            it "can infer the message type through a provide" do
                parent_combus = self.combus
                combus = ComBus.new_submodel { provides parent_combus }
                assert_equal @test_t, combus.message_type
            end

            it "does not allow to override the message type in submodels through the argument" do
                assert_raises(ArgumentError) { combus.new_submodel message_type: "/double" }
            end

            it "does not allow to override the mesage type in submodels through #provides" do
                parent_combus = self.combus
                combus = ComBus.new_submodel { provides parent_combus }
                other_combus = ComBus.new_submodel message_type: "/double"
                assert_raises(ArgumentError) { combus.provides other_combus }
            end

            it "cannot provide a ComBus that does not have the same message type" do
                other_combus = ComBus.new_submodel message_type: "/double"
                assert_raises(ArgumentError) { combus.provides other_combus }
            end

            it "requires the message type" do
                assert_raises(ArgumentError) { ComBus.new_submodel }
            end

            describe "the definition of interface services" do
                it "defines a client_in service" do
                    assert combus.client_in_srv
                end
                it "defines a client_out service" do
                    assert combus.client_out_srv
                end
                it "defines a bus_in service" do
                    assert combus.bus_in_srv
                end
                it "defines a bus_out service" do
                    assert combus.bus_out_srv
                end
            end
        end

        describe "the DSL definition" do
            attr_reader :mod
            before do
                @mod = Module.new
            end

            it "registers the services as constant on the receiver" do
                srv = mod.com_bus_type "Image", message_type: "/double"
                assert_same srv, mod::Image
            end
        end
    end
end
