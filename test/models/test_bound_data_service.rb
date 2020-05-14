# frozen_string_literal: true

require "syskit/test/self"
require "./test/fixtures/simple_composition_model"

describe Syskit::Models::BoundDataService do
    include Syskit::Fixtures::SimpleCompositionModel

    def setup_transitive_services
        base = Syskit::DataService.new_submodel do
            input_port "in_base", "/int"
            input_port "in_base_unmapped", "/double"
            output_port "out_base", "/int"
            output_port "out_base_unmapped", "/double"
        end
        parent = Syskit::DataService.new_submodel do
            input_port "in_parent", "/int"
            input_port "in_parent_unmapped", "/double"
            output_port "out_parent", "/int"
            output_port "out_parent_unmapped", "/double"
        end
        parent.provides base, "in_base" => "in_parent", "out_base" => "out_parent"
        model = Syskit::DataService.new_submodel do
            input_port "in_model", "/int"
            output_port "out_model", "/int"
        end
        model.provides parent, "in_parent" => "in_model", "out_parent" => "out_model"

        component_model = Syskit::TaskContext.new_submodel do
            input_port "in_port", "/int"
            output_port "out_port", "/int"
            output_port "other_port", "/int"

            input_port "in_parent_unmapped", "/double"
            input_port "in_base_unmapped", "/double"
            output_port "out_parent_unmapped", "/double"
            output_port "out_base_unmapped", "/double"
        end
        service = component_model.provides(
            model, { "in_model" => "in_port", "out_model" => "out_port" }, as: "test"
        )

        [base, parent, model, component_model, service]
    end

    describe "#self_port_to_component_port" do
        attr_reader :stub_t
        before do
            @stub_t = stub_type "/test_t"
            create_simple_composition_model
        end

        it "should return the port mapped on the task" do
            task_m = simple_component_model
            srv_m  = task_m.srv_srv
            port = flexmock(name: "srv_port")
            flexmock(srv_m).should_receive(:port_mappings_for_task).and_return("srv_port" => "component_port")
            flexmock(task_m).should_receive(:find_port).with("component_port").and_return(obj = Object.new)
            assert_equal obj, srv_m.self_port_to_component_port(port)
        end
    end

    describe "DRoby marshalling" do
        attr_reader :srv_m, :task_m, :stub_t
        before do
            @stub_t = stub_type "/test_t"
            create_simple_composition_model
            @task_m = simple_component_model
            @srv_m  = task_m.srv_srv
        end

        it "should create a new service object when done on an anonymous model" do
            dump = srv_m.droby_dump(Roby::DRoby::Marshal.new)
            loaded = Marshal.load(Marshal.dump(dump))
            loaded = loaded.proxy(Roby::DRoby::Marshal.new)
            assert_equal "srv", loaded.name
        end
    end

    describe "#find_data_service" do
        it "returns a slave service if it exists" do
            srv_m = Syskit::DataService.new_submodel
            slave_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel do
                provides srv_m, as: "master"
                provides slave_m, as: "slave"
            end
            assert_same task_m.find_data_service("master.slave"), task_m.master_srv.find_data_service("slave")
        end
        it "won't return a master service of the same name than the requested slave" do
            srv_m = Syskit::DataService.new_submodel
            slave_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel do
                provides srv_m, as: "master"
                provides slave_m, as: "slave"
            end
            assert_same task_m.find_data_service("master.slave"), task_m.master_srv.find_data_service("master")
        end
    end

    describe "#method_missing" do
        it "gives direct access to slave services" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }
            master = task_m.master_srv
            flexmock(master).should_receive(:find_data_service).once.with("slave").and_return(obj = Object.new)
            assert_same obj, master.slave_srv
        end
        it "raises ArgumentError if arguments are given" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }
            master = task_m.master_srv
            e = assert_raises(ArgumentError) { master.slave_srv("an_argument") }
            assert_equal "expected zero arguments to slave_srv, got 1", e.message
        end
        it "raises NoMethodError if the requested service does not exist" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }
            master = task_m.master_srv
            flexmock(master).should_receive(:find_data_service).once.with("slave").and_return(nil)
            e = assert_raises(NoMethodError) { master.slave_srv }
            assert_equal :slave_srv, e.name
        end
    end

    describe "#bind" do
        attr_reader :srv_m, :task_m
        before do
            srv_m = Syskit::DataService.new_submodel
            @task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: "test" }
            @srv_m = task_m.test_srv
        end
        it "can bind to a bound data service of the right model" do
            srv = task_m.new.test_srv
            assert_equal srv, srv_m.bind(srv)
        end
        it "can bind to an instance of the right model" do
            task = task_m.new
            srv = task.test_srv
            assert_equal srv, srv_m.bind(task)
        end
        it "raises ArgumentError if the provided component model is of an invalid type" do
            assert_raises(ArgumentError) { srv_m.bind(Syskit::TaskContext.new_submodel.new) }
        end
        it "is available as #resolve for backward compatibility" do
            flexmock(Roby).should_receive(:warn_deprecated)
                          .with(/resolve/).once
            task = task_m.new
            srv = task.test_srv
            assert_equal srv, srv_m.resolve(task)
        end

        describe "behaviour related to placeholder models" do
            attr_reader :srv_m, :other_srv_m, :component_m, :placeholder_m, :task_m
            before do
                @srv_m = Syskit::DataService.new_submodel
                @other_srv_m = Syskit::DataService.new_submodel
                @component_m = Syskit::TaskContext.new_submodel
                component_m.provides srv_m, as: "test"
                @placeholder_m = Syskit::Models::Placeholder.for([other_srv_m], component_model: component_m)
                @task_m = component_m.new_submodel
                task_m.provides other_srv_m, as: "other"
            end
            it "resolves a placeholder model's base model service by name" do
                # Add an ambiguous service to ensure that #bind resolves the
                # right one
                task_m.provides srv_m, as: "ambiguous"
                task = task_m.new
                assert_equal component_m.test_srv.bind(task), placeholder_m.test_srv.bind(task)
            end
            it "resolves a placeholder service by type" do
                task = task_m.new
                assert_equal task.other_srv, placeholder_m.find_data_service_from_type(other_srv_m).bind(task)
            end

            it "raises if trying to resolve an ambiguous service" do
                task_m.provides other_srv_m, as: "ambiguous"
                task = task_m.new
                assert_raises(Syskit::AmbiguousServiceSelection) do
                    placeholder_m.find_data_service_from_type(other_srv_m).bind(task)
                end
            end
        end

        describe "behavior related to dynamic data services" do
            before do
                @srv_m = srv_m = Syskit::DataService.new_submodel
                @task_m = Syskit::TaskContext.new_submodel do
                    dynamic_service srv_m, as: "test" do
                        provides srv_m
                    end
                end
            end

            it "binds a dynamic data service horizontally" do
                sub1_m = @task_m.specialize
                sub1_m.require_dynamic_service "test", as: "test"
                sub2_m = @task_m.specialize
                sub2_m.require_dynamic_service "test", as: "test"

                task = sub2_m.new
                assert_equal task.test_srv, sub1_m.test_srv.bind(task)
            end

            it "refuse binding two services that don't come from the same dynamic service" do
                srv_m = @srv_m # for the block
                @task_m.dynamic_service srv_m, as: "other" do
                    provides srv_m
                end
                sub1_m = @task_m.specialize
                sub1_m.require_dynamic_service "test", as: "test"
                sub2_m = @task_m.specialize
                sub2_m.require_dynamic_service "other", as: "test"

                task = sub2_m.new
                e = assert_raises(ArgumentError) do
                    sub1_m.test_srv.bind(task)
                end
                assert_equal "cannot bind #{sub1_m.test_srv} on #{task}: does not fullfill #{sub1_m.test_srv.component_model}",
                             e.message
            end
        end
    end

    describe "#fullfills?" do
        attr_reader :base, :parent, :model, :component_model, :service
        before do
            @base, @parent, @model, @component_model, @service =
                setup_transitive_services
        end

        it "returns false for component models" do
            assert !service.fullfills?(component_model)
            assert !service.fullfills?([component_model, base])
        end

        it "returns true for its own data service model" do
            assert service.fullfills?(model)
        end

        it "returns true for provided services" do
            assert service.fullfills?(base)
            assert service.fullfills?(parent)
        end

        it "returns false for services that it does not provide" do
            other_service = Syskit::DataService.new_submodel
            refute service.fullfills?(other_service)
        end

        it "returns true for service proxies that list provided services" do
            proxy = parent.placeholder_model
            assert service.fullfills?(proxy)
        end
    end

    describe "#fullfilled_model" do
        it "should return the service model" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::Component.new_submodel
            task_m.provides srv_m, as: "test"
            assert_equal [srv_m], task_m.test_srv.fullfilled_model
        end
    end

    describe "#attach" do
        attr_reader :srv, :task_m
        before do
            srv_m = Syskit::DataService.new_submodel do
                output_port "out", "/double"
            end
            @task_m = Syskit::TaskContext.new_submodel do
                output_port "out", "/double"
            end
            @srv = task_m.provides srv_m, as: "test"
        end
        it "should return itself if given itself" do
            assert_equal srv, srv.attach(srv)
        end
        it "should raise ArgumentError if the new component model is not a submodel of the current component model" do
            assert_raises(ArgumentError) do
                srv.attach(Syskit::TaskContext.new_submodel)
            end
        end
        it "should return the service with the same name on the new component model" do
            subtask_m = task_m.new_submodel
            assert_equal subtask_m.test_srv, srv.attach(subtask_m)
        end
        it "clears the ports cache on the returned value" do
            # This tests for a regression. The port cache on the bound data
            # service was not cleared in #attach, which led already-accessed
            # ports to leak onto the newly attached service. These already
            # accessed port would point to the wrong component model, though,
            # obviously
            subtask_m = task_m.new_submodel
            srv.out_port
            attached = srv.attach(subtask_m)
            assert_equal subtask_m, attached.out_port.to_component_port.component_model
        end
    end

    describe "#==" do
        attr_reader :parent_srv_m, :srv_m, :task_m
        before do
            @parent_srv_m = Syskit::DataService.new_submodel
            @srv_m = Syskit::DataService.new_submodel
            srv_m.provides parent_srv_m
            @task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
        end

        it "returns true for two different instances pointing to the same service" do
            srv = task_m.test_srv
            assert_equal srv, srv.dup
        end
        it "returns false for a faceted service" do
            refute_equal task_m.test_srv.as(parent_srv_m), task_m.test_srv
        end
    end

    describe "#find_port_for_task_port" do
        attr_reader :stub_t, :srv_m
        before do
            @stub_t = stub_t = stub_type "/test_t"
            @srv_m = Syskit::DataService.new_submodel do
                output_port "out", stub_t
            end
        end
        it "returns the task port that maps to a service port" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out", stub_t
            end
            task_m.provides srv_m, as: "test"
            assert_equal task_m.test_srv.out_port,
                         task_m.test_srv.find_port_for_task_port(task_m.task_out_port)
        end

        it "returns nil if there is no mapping" do
            stub_t = self.stub_t
            task_m = Syskit::TaskContext.new_submodel do
                output_port "task_out", stub_t
                output_port "other_out", stub_t
            end
            task_m.provides srv_m, { "out" => "other_out" }, as: "test"
            assert_nil task_m.test_srv.find_port_for_task_port(task_m.task_out_port)
        end
    end

    describe "#demoted" do
        before do
            @task_m = Syskit::TaskContext.new_submodel
            srv_m = Syskit::DataService.new_submodel
            @bound_srv_m = @task_m.provides srv_m, as: "test"
        end

        it "returns self if called from the base model" do
            assert_same @bound_srv_m, @bound_srv_m.demoted
        end
        it "returns the parent's model if called from a promoted model" do
            sub_m = @task_m.new_submodel
            refute_equal @bound_srv_m, sub_m.find_data_service("test")
            assert_same @bound_srv_m, sub_m.find_data_service("test").demoted
        end
        it "returns the initial model regardless of the number of levels" do
            sub_m = @task_m.new_submodel
            subsub_m = sub_m.new_submodel
            refute_equal @bound_srv_m, subsub_m.find_data_service("test")
            assert_same @bound_srv_m, subsub_m.find_data_service("test").demoted
        end
    end

    describe "#same_service?" do
        before do
            @task_m = Syskit::TaskContext.new_submodel
            @srv_m  = srv_m = Syskit::DataService.new_submodel
            @bound_srv_m = @task_m.provides @srv_m, as: "test"
        end

        it "returns true if it is the same service" do
            assert @bound_srv_m.same_service?(@bound_srv_m)
        end
        it "returns true if it has been promoted from the same root service" do
            left_m = @task_m.new_submodel
            right_m = @task_m.new_submodel
            assert left_m.test_srv.same_service?(right_m.test_srv)
        end
        it "returns true even if there are more than one level of promotion" do
            left_m = @task_m.new_submodel
            sub_m = @task_m.new_submodel
            right_m = sub_m.specialize
            assert left_m.test_srv.same_service?(right_m.test_srv)
        end
        it "returns false for different services" do
            other_srv_m = @task_m.provides @srv_m, as: "other"
            refute @bound_srv_m.same_service?(other_srv_m)
        end
        it "returns false for services defined separately even if with the same definition" do
            left_m = @task_m.new_submodel
            left_srv_m = left_m.provides @srv_m, as: "separate"
            right_m = @task_m.new_submodel
            right_srv_m = right_m.provides @srv_m, as: "separate"
            refute left_srv_m.same_service?(right_srv_m)
        end
    end
end

module Syskit
    class TC_Models_BoundDataService < Minitest::Test
        DataService = Syskit::DataService

        def setup_stereocamera
            service_model = DataService.new_submodel do
                output_port "image", "/int"
            end
            other_service_model = DataService.new_submodel
            component_model = Syskit::TaskContext.new_submodel do
                output_port "left", "/int"
                output_port "right", "/int"
            end
            left_srv = component_model.provides(
                service_model, { "image" => "left" }, as: "left"
            )
            right_srv = component_model.provides(
                service_model, { "image" => "right" }, as: "right"
            )
            component_model.provides other_service_model, as: "other_srv"
            [service_model, other_service_model, component_model, left_srv, right_srv]
        end

        def setup_transitive_services
            base = DataService.new_submodel do
                input_port "in_base", "/int"
                input_port "in_base_unmapped", "/double"
                output_port "out_base", "/int"
                output_port "out_base_unmapped", "/double"
            end
            parent = DataService.new_submodel do
                input_port "in_parent", "/int"
                input_port "in_parent_unmapped", "/double"
                output_port "out_parent", "/int"
                output_port "out_parent_unmapped", "/double"
            end
            parent.provides base, "in_base" => "in_parent", "out_base" => "out_parent"
            model = DataService.new_submodel do
                input_port "in_model", "/int"
                output_port "out_model", "/int"
            end
            model.provides parent, "in_parent" => "in_model", "out_parent" => "out_model"

            component_model = Syskit::TaskContext.new_submodel do
                input_port "in_port", "/int"
                output_port "out_port", "/int"
                output_port "other_port", "/int"

                input_port "in_parent_unmapped", "/double"
                input_port "in_base_unmapped", "/double"
                output_port "out_parent_unmapped", "/double"
                output_port "out_base_unmapped", "/double"
            end
            service = component_model.provides(
                model,
                { "in_model" => "in_port", "out_model" => "out_port" },
                as: "test"
            )

            [base, parent, model, component_model, service]
        end

        def test_root_service
            component_model = TaskContext.new_submodel
            service_model = DataService.new_submodel
            other_service_model = DataService.new_submodel
            service = component_model.provides service_model, as: "service"
            component_model.provides other_service_model, as: "other_service"
            assert_equal component_model, service.component_model
            assert service.master?
            assert_equal("service", service.full_name)
            assert_equal("service", service.name)
            assert(service.fullfills?(service_model))
            assert(!service.fullfills?(other_service_model))
        end

        def test_each_fullfilled_model
            base, parent, model, component_model, service =
                setup_transitive_services

            other_service = DataService.new_submodel
            component_model.provides other_service, as: "unrelated_service"

            assert_equal [base, parent, model, DataService].to_set,
                         service.each_fullfilled_model.to_set
        end

        def test_port_mappings
            service_model, other_service_model, component_model, left_srv, right_srv =
                setup_stereocamera
            assert_equal({ "image" => "left" }, left_srv.port_mappings_for_task)
        end

        def test_output_port_access_through_method_missing
            base, parent, model, component_model, service =
                setup_transitive_services
            assert_same service.find_output_port("out_model"), service.out_model_port
        end

        def test_port_mappings_transitive_services
            base, parent, model, component_model, service =
                setup_transitive_services

            assert_equal({ "in_model" => "in_port",
                           "in_parent_unmapped" => "in_parent_unmapped",
                           "in_base_unmapped" => "in_base_unmapped",
                           "out_model" => "out_port",
                           "out_parent_unmapped" => "out_parent_unmapped",
                           "out_base_unmapped" => "out_base_unmapped" },
                         service.port_mappings_for_task)
            assert_equal({ "in_parent" => "in_port",
                           "in_parent_unmapped" => "in_parent_unmapped",
                           "in_base_unmapped" => "in_base_unmapped",
                           "out_parent" => "out_port",
                           "out_parent_unmapped" => "out_parent_unmapped",
                           "out_base_unmapped" => "out_base_unmapped" },
                         service.port_mappings_for(parent))
            assert_equal({ "in_base" => "in_port",
                           "in_base_unmapped" => "in_base_unmapped",
                           "out_base" => "out_port",
                           "out_base_unmapped" => "out_base_unmapped" },
                         service.port_mappings_for(base))
        end

        def assert_ports_equal(component_model, names, result)
            result.each do |p|
                assert_same component_model, p.component_model
                assert names.include?(p.name), "#{p.name} was not expected to be in the port list #{names.to_a.sort.join(', ')}"
            end
        end

        def test_each_output_port
            base, parent, model, component_model, service =
                setup_transitive_services

            assert_ports_equal service, %w[out_base_unmapped out_parent_unmapped out_model],
                               service.each_output_port
        end

        def test_each_input_port
            base, parent, model, component_model, service =
                setup_transitive_services
            assert_ports_equal service, %w[in_base_unmapped in_parent_unmapped in_model],
                               service.each_input_port
        end

        def test_narrowed_find_input_port_gives_access_to_unmapped_ports
            base, parent, model, component_model, service_model =
                setup_transitive_services
            service = service_model.as(parent)
            assert service.find_input_port("in_parent_unmapped")
            assert service.find_input_port("in_base_unmapped")
        end

        def test_narrowed_find_input_port_returns_nil_on_unmapped_ports_from_its_original_type
            base, parent, model, component_model, service_model =
                setup_transitive_services
            service = service_model.as(base)
            assert !service.find_input_port("in_parent_unmapped")
        end

        def test_narrowed_find_input_port_gives_access_to_mapped_ports
            base, parent, model, component_model, service_model =
                setup_transitive_services
            service = service_model.as(parent)
            assert service.find_input_port("in_parent")
        end

        def test_narrowed_find_input_port_returns_nil_on_mapped_ports_from_its_original_type
            base, parent, model, component_model, service_model =
                setup_transitive_services
            service = service_model.as(parent)
            assert !service.find_input_port("in_port")
        end

        def test_narrowed_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
            base, parent, model, component_model, service_model =
                setup_transitive_services
            service = service_model.as(parent)
            assert !service.find_input_port("in_base")
        end
    end
end
