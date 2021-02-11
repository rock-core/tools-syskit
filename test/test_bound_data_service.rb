# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::BoundDataService do
    describe "#to_s" do
        it "should return a string" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel { provides srv_m, as: "srv" }
            assert_kind_of String, task_m.new.srv_srv.to_s
        end
    end

    describe "#find_data_service" do
        it "returns a slave service if it exists" do
            srv_m = Syskit::DataService.new_submodel
            slave_m = Syskit::DataService.new_submodel
            task = Syskit::TaskContext.new_submodel do
                provides srv_m, as: "master"
                provides slave_m, as: "slave"
            end.new
            assert_same task.find_data_service("master.slave"), task.master_srv.find_data_service("slave")
        end
        it "won't return a master service of the same name than the requested slave" do
            srv_m = Syskit::DataService.new_submodel
            slave_m = Syskit::DataService.new_submodel
            task = Syskit::TaskContext.new_submodel do
                provides srv_m, as: "master"
                provides slave_m, as: "slave"
            end.new
            assert_same task.find_data_service("master.slave"), task.master_srv.find_data_service("master")
        end
    end

    describe "#method_missing" do
        it "gives direct access to slave services" do
            srv_m = Syskit::DataService.new_submodel
            task = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }.new
            master = task.master_srv
            flexmock(master).should_receive(:find_data_service).once.with("slave").and_return(obj = Object.new)
            assert_same obj, master.slave_srv
        end
        it "raises ArgumentError if arguments are given" do
            srv_m = Syskit::DataService.new_submodel
            task = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }.new
            master = task.master_srv
            e = assert_raises(ArgumentError) { master.slave_srv("an_argument") }
            assert_equal "expected zero arguments to slave_srv, got 1", e.message
        end
        it "raises NoMethodError if the requested service does not exist" do
            srv_m = Syskit::DataService.new_submodel
            task = Syskit::TaskContext.new_submodel { provides srv_m, as: "master" }.new
            master = task.master_srv
            flexmock(master).should_receive(:find_data_service).once.with("slave").and_return(nil)
            e = assert_raises(NoMethodError) { master.slave_srv }
            assert_equal :slave_srv, e.name
        end
    end
end

class TC_BoundDataService < Minitest::Test
    DataService = Syskit::DataService

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
            model, { "in_model" => "in_port", "out_model" => "out_port" }, as: "test"
        )

        [base, parent, model, component_model, service]
    end

    def test_find_input_port_gives_access_to_unmapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        task = syskit_stub_deploy_and_configure(component_model)
        service = service_model.bind(task)
        assert_equal task.find_input_port("in_parent_unmapped"), service.find_input_port("in_parent_unmapped").to_component_port
        assert_equal task.find_input_port("in_base_unmapped"), service.find_input_port("in_base_unmapped").to_component_port
    end

    def test_find_input_port_gives_access_to_mapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        task = syskit_stub_deploy_and_configure(component_model)
        service = service_model.bind(task)
        assert_equal task.find_input_port("in_port"), service.find_input_port("in_model").to_component_port
    end

    def test_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(component_model.new)
        assert !service.find_input_port("in_parent")
        assert !service.find_input_port("in_base")
    end

    def test_find_input_port_returns_nil_on_a_task_port_that_is_not_a_service_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.bind(component_model.new)
        assert !service.find_input_port("other_port")
    end

    def test_narrowed_find_input_port_gives_access_to_unmapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        task = syskit_stub_deploy_and_configure(component_model)
        service = service_model.as(parent).bind(task)
        assert_equal task.find_input_port("in_parent_unmapped"), service.find_input_port("in_parent_unmapped").to_component_port
        assert_equal task.find_input_port("in_base_unmapped"), service.find_input_port("in_base_unmapped").to_component_port
    end

    def test_narrowed_find_input_port_returns_nil_on_unmapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(base).bind(component_model.new)
        assert !service.find_input_port("in_parent_unmapped")
    end

    def test_narrowed_find_input_port_gives_access_to_mapped_ports
        base, parent, model, component_model, service_model =
            setup_transitive_services
        task = syskit_stub_deploy_and_configure(component_model)
        service = service_model.as(parent).bind(task = component_model.new)
        assert_equal task.find_input_port("in_port"), service.find_input_port("in_parent").to_component_port
    end

    def test_narrowed_find_input_port_returns_nil_on_mapped_ports_from_its_original_type
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(component_model.new)
        assert !service.find_input_port("in_port")
    end

    def test_narrowed_find_input_port_returns_nil_on_the_original_name_of_a_mapped_port
        base, parent, model, component_model, service_model =
            setup_transitive_services
        service = service_model.as(parent).bind(component_model.new)
        assert !service.find_input_port("in_base")
    end

    def test_connect_ports_task_to_service
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        # the connect_ports call should translate service ports to actual ports
        # and pass on to add_sink
        flexmock(source_task).should_receive(:add_sink)
                             .once.with(sink_task, { %w[out_port in_port] => {} })
        source_task.out_port_port.connect_to sink_task.test_srv.in_model_port
    end

    def test_connect_ports_task_to_narrowed_service
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        sink = sink_task.test_srv.as(parent)

        # the connect_ports call should translate service ports to actual ports
        # and pass on to add_sink
        flexmock(source_task).should_receive(:add_sink)
                             .once.with(sink_task, { %w[out_port in_port] => {} })
        source_task.out_port_port.connect_to sink.in_parent_port
    end

    def test_connect_ports_service_to_task
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        source = source_task.test_srv

        flexmock(source_task).should_receive(:add_sink)
                             .once.with(sink_task, { %w[out_port in_port] => {} })
        source.out_model_port.connect_to sink_task.in_port_port
    end

    def test_connect_ports_narrowed_service_to_task
        base, parent, model, component_model, service =
            setup_transitive_services
        plan.add(source_task = component_model.new)
        plan.add(sink_task = component_model.new)

        source = source_task.test_srv.as(parent)

        flexmock(source_task).should_receive(:add_sink)
                             .once.with(sink_task, { %w[out_port in_port] => {} })

        source.out_parent_port.connect_to sink_task.in_port_port
    end

    def test_fullfills_p
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.bind(component_model.new)

        other_service = DataService.new_submodel
        component_model.provides other_service, as: "unrelated_service"

        assert !service.fullfills?(component_model)
        assert service.fullfills?(base)
        assert service.fullfills?(parent)
        assert service.fullfills?(model)
        assert !service.fullfills?(other_service)
    end

    def test_each_fullfilled_model
        base, parent, model, component_model, service =
            setup_transitive_services
        service = service.bind(component_model.new)

        other_service = DataService.new_submodel
        component_model.provides other_service, as: "unrelated_service"

        assert_equal [base, parent, model, DataService].to_set,
                     service.each_fullfilled_model.to_set
    end
end
