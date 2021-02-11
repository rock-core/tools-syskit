# frozen_string_literal: true

require "syskit/test/self"

describe Syskit::DependencyInjection do
    describe "#selection_for" do
        it "returns an existing instance if one is selected" do
            task = Syskit::Component.new_submodel.new
            di = Syskit::DependencyInjection.new("child" => task)
            result = di.selection_for("child", Syskit::InstanceRequirements.new)
            assert_equal [task, Syskit::InstanceRequirements.new([task.model]), {}, ["child"].to_set], result
        end
        it "validates the instance with the provided requirements and pass if it fullfills" do
            task = Syskit::Component.new_submodel.new
            di = Syskit::DependencyInjection.new("child" => task)

            requirements = task.model.to_instance_requirements
            flexmock(task).should_receive(:fullfills?).with(requirements, {}).and_return(true)
            result = di.selection_for("child", requirements)
            assert_equal [task, Syskit::InstanceRequirements.new([task.model]), {}, ["child"].to_set], result
        end
        it "validates the instance with the provided requirements and raises if it does not match" do
            task = Syskit::Component.new_submodel.new
            di = Syskit::DependencyInjection.new("child" => task)

            requirements = task.model.to_instance_requirements
            flexmock(task).should_receive(:fullfills?).with(requirements, {}).and_return(false)
            assert_raises(ArgumentError) do
                di.selection_for("child", requirements)
            end
        end
        it "returns an existing instance service if one is selected and required" do
            srv = Syskit::DataService.new_submodel
            task = Syskit::Component.new_submodel { provides srv, as: "srv" }.new
            di = Syskit::DependencyInjection.new("child" => task.srv_srv)

            instance, requirements, services = di.selection_for("child", Syskit::InstanceRequirements.new([srv]))
            assert_equal task, instance
            assert_equal Syskit::InstanceRequirements.new([task.model]), requirements
            assert_equal Hash[srv => task.model.srv_srv], services
        end
        it "maps name-to-service selections to the requirements" do
            base_srv_m = Syskit::DataService.new_submodel
            srv_m = Syskit::DataService.new_submodel
            srv_m.provides base_srv_m
            task_m = Syskit::Component.new_submodel
            task_m.provides srv_m, as: "test"
            di = Syskit::DependencyInjection.new("child" => task_m.test_srv)
            _, _, service_selections = di.selection_for("child", Syskit::InstanceRequirements.new([base_srv_m]))
            assert_equal task_m.test_srv, service_selections[base_srv_m]
        end
        it "uses service-to-bound_service selections as service mappings when matching the task model" do
            base_srv_m = Syskit::DataService.new_submodel
            srv_m = Syskit::DataService.new_submodel
            srv_m.provides base_srv_m
            task_m = Syskit::Component.new_submodel
            task_m.provides srv_m, as: "test"
            task_m.provides srv_m, as: "ambiguous"
            di = Syskit::DependencyInjection.new("child" => task_m, srv_m => task_m.test_srv)
            _, _, service_selections = di.selection_for("child", Syskit::InstanceRequirements.new([base_srv_m]))
            assert_equal task_m.test_srv, service_selections[base_srv_m]
        end
        it "will accept DependencyInjection.nothing as a selection, thus overriding more general selections" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
            di = Syskit::DependencyInjection.new(
                "child" => Syskit::DependencyInjection.nothing, srv_m => task_m
            )
            _, requirements, = di.selection_for("child", srv_m)
            assert_equal srv_m.placeholder_model, requirements.model
        end
        it "will accept DependencyInjection.do_not_inherit as a selection, thus falling back to more general selections" do
            srv_m  = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
            di = Syskit::DependencyInjection.new(
                "child" => Syskit::DependencyInjection.do_not_inherit, srv_m => task_m
            )
            _, requirements, = di.selection_for("child", srv_m)
            assert_equal task_m, requirements.model
        end
    end

    describe "#instance_selection_for" do
        it "propagates the abstract flag" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
            di = Syskit::DependencyInjection.new("child" => task_m.to_instance_requirements.abstract)
            assert di.instance_selection_for("child", task_m.to_instance_requirements)[0].selected.abstract?
            di = Syskit::DependencyInjection.new(task_m => task_m.to_instance_requirements.abstract)
            assert di.instance_selection_for(nil, task_m.to_instance_requirements)[0].selected.abstract?
            di = Syskit::DependencyInjection.new("child" => srv_m.to_instance_requirements.abstract, srv_m => task_m)
            assert di.instance_selection_for("child", task_m.to_instance_requirements)[0].selected.abstract?
        end
    end

    describe "#add" do
        attr_reader :di, :explicit_m, :default_m
        before do
            @di = flexmock(Syskit::DependencyInjection.new)
            @explicit_m = Syskit::TaskContext.new_submodel
            @default_m = Syskit::TaskContext.new_submodel
        end

        it "normalizes the explicit arguments" do
            flexmock(Syskit::DependencyInjection).should_receive(:normalize_selection).with("test" => explicit_m).once.pass_thru
            di.add("test" => explicit_m)
        end
        it "normalizes the default arguments" do
            flexmock(Syskit::DependencyInjection).should_receive(:normalize_selected_object).with(m = flexmock).once.and_return(default_m)
            di.should_receive(:add_defaults).with([default_m].to_set).once
            di.add(m)
        end
        it "merges new default arguments with the existing ones" do
            a_m = Syskit::TaskContext.new_submodel
            b_m = Syskit::TaskContext.new_submodel
            di = Syskit::DependencyInjection.new
            flexmock(di).should_receive(:add_defaults).with([a_m, b_m].to_set).once
            flexmock(di).should_receive(:add_explicit).with({}).once
            di.add(a_m, b_m)
        end
        it "adds both explicit selections and defaults from given DI objects" do
            a_m = Syskit::TaskContext.new_submodel
            b_m = Syskit::TaskContext.new_submodel
            added = Syskit::DependencyInjection.new
            added.add(a_m, "test" => b_m)
            di = Syskit::DependencyInjection.new
            flexmock(di).should_receive(:add_defaults).with([a_m].to_set).once
            flexmock(di).should_receive(:add_explicit).with("test" => b_m).once
            di.add(added)
        end
    end

    describe "#add_explicit" do
        it "does not modify the selections if given an identity mapping" do
            a = Syskit::DataService.new_submodel(name: "A")
            b = Syskit::DataService.new_submodel(name: "B") { provides a }
            di = Syskit::DependencyInjection.new(a => b)
            di.add(a => a)
            assert_equal Hash[a => b], di.explicit
        end
    end

    describe "#resolve_recursive_selection_mapping" do
        it "resolves component models recursively" do
            srv0 = Syskit::DataService.new_submodel
            srv1 = Syskit::DataService.new_submodel
            srv1.provides srv0
            mapping = { "value" => srv0, srv0 => srv1 }
            assert_equal({ "value" => srv1, srv0 => srv1 },
                         Syskit::DependencyInjection.resolve_recursive_selection_mapping(mapping))
        end

        it "does not resolve names" do
            mapping = { "name" => "value", "value" => "bla" }
            assert_equal(mapping,
                         Syskit::DependencyInjection.resolve_recursive_selection_mapping(mapping))
        end

        it "resolves the component model of bound data services" do
            srv_m = Syskit::DataService.new_submodel
            proxy_m = srv_m.placeholder_model
            proxy2_m = srv_m.placeholder_model
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"

            mapping = { srv_m => proxy_m.m0_srv, proxy_m => proxy2_m, proxy2_m => task_m }
            assert_equal(task_m.test_srv,
                         Syskit::DependencyInjection.resolve_recursive_selection_mapping(mapping)[srv_m])
        end

        it "properly maintains already resolved bound data services if an indentity selection is present" do
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel
            task_m.provides srv_m, as: "test"
            task_m.provides srv_m, as: "ambiguous"

            mapping = { srv_m => task_m.test_srv, task_m => task_m }
            assert_equal(task_m.test_srv,
                         Syskit::DependencyInjection.resolve_recursive_selection_mapping(mapping)[srv_m])
        end
    end

    describe "#merge" do
        attr_reader :model0, :model1, :di0, :di1
        before do
            @model0 = flexmock(Syskit::InstanceRequirements.new)
            @model1 = flexmock(Syskit::InstanceRequirements.new)
            model0.should_receive(:==).with(model1).and_return(false)
            model1.should_receive(:==).with(model0).and_return(false)
            @di0 = Syskit::DependencyInjection.new("test" => model0)
            @di1 = Syskit::DependencyInjection.new("test" => model1)
        end

        it "should simply pass on identical models" do
            model0.should_receive(:==).with(model1).and_return(true)
            di0.merge(di1)
            assert_same model0, di0.explicit["test"]
        end

        it "should use the most-specific model if both DI objects have conflicting selections" do
            model0.should_receive(:fullfills?).with(model1).and_return(true)
            model1.should_receive(:fullfills?).with(model0).and_return(false)

            di0 = self.di0.dup
            di1 = self.di1.dup
            di0.merge(di1)
            assert_same model0, di0.explicit["test"]

            # Test the other way around
            di0 = self.di0.dup
            di1 = self.di1.dup
            di1.merge(di0)
            assert_same model0, di1.explicit["test"]
        end

        it "should raise if conflicting selections cannot be resolved" do
            model0.should_receive(:fullfills?).with(model1).and_return(false)
            model1.should_receive(:fullfills?).with(model0).and_return(false)

            assert_raises(ArgumentError) do
                di0.merge(di1)
            end
        end
    end
end

module Syskit
    class TC_DependencyInjection < Minitest::Test
        def test_to_s
            # Just checking that it does not raise and returns a string
            di = DependencyInjection.new("val", "name" => "value")
            assert_respond_to di.to_s, :to_s
        end

        def test_new_object_with_initial_selection
            component_model = Component.new_submodel
            dep = DependencyInjection.new(component_model, "name" => "value")
            assert_equal({ "name" => "value" }, dep.explicit)
            assert_equal [component_model], dep.defaults.to_a
        end

        def test_new_object_is_empty
            dep = DependencyInjection.new
            assert dep.empty?
        end

        def test_cleared_object_is_empty
            dep = DependencyInjection.new
            dep.add "name" => "value"
            dep.clear
            assert dep.empty?
        end

        def test_adding_explicit_selection_makes_the_object_not_empty
            dep = DependencyInjection.new
            dep.add "name" => "value"
            assert !dep.empty?
        end

        def test_adding_implicit_selection_makes_the_object_not_empty
            dep = DependencyInjection.new
            dep.add Component.new_submodel
            assert !dep.empty?
        end

        def test_pretty_print
            dep = DependencyInjection.new(Component.new_submodel, DataService.new_submodel => "value")
            # Just verify that it does not raise ...
            PP.pp(dep, "".dup)
        end

        def test_normalize_selection_raises_on_invalid_keys
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(nil => "value") }
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(Object.new => "value") }
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(Class.new => "value") }
        end

        def test_normalize_selection_accepts_string_to_allowed_values
            srv = DataService.new_submodel
            component = Component.new_submodel
            component.provides srv, as: "srv"
            key = "key"
            assert_equal(Hash[key => DependencyInjection.nothing], DependencyInjection.normalize_selection(key => DependencyInjection.nothing))
            assert_equal(Hash[key => DependencyInjection.do_not_inherit], DependencyInjection.normalize_selection(key => DependencyInjection.do_not_inherit))
            assert_equal(Hash[key => "value"], DependencyInjection.normalize_selection(key => "value"))
            assert_equal(Hash[key => srv], DependencyInjection.normalize_selection(key => srv))
            assert_equal(Hash[key => component], DependencyInjection.normalize_selection(key => component))
            assert_equal(Hash[key => component.srv_srv], DependencyInjection.normalize_selection(key => component.srv_srv))
            component = component.new
            assert_equal(Hash[key => component], DependencyInjection.normalize_selection(key => component))
            assert_equal(Hash[key => component.srv_srv], DependencyInjection.normalize_selection(key => component.srv_srv))
            req = InstanceRequirements.new
            assert_equal(Hash[key => req], DependencyInjection.normalize_selection(key => req))
        end

        def test_normalize_selection_rejects_string_to_arbitrary
            key = "key"
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => Object.new) }
        end

        def test_normalize_selection_accepts_component_to_nil_string_and_identity
            srv = DataService.new_submodel
            component = Component.new_submodel
            component.provides srv, as: "srv"
            key = component

            assert_equal(Hash[key => DependencyInjection.nothing], DependencyInjection.normalize_selection(key => DependencyInjection.nothing))
            assert_equal(Hash[key => DependencyInjection.do_not_inherit], DependencyInjection.normalize_selection(key => DependencyInjection.do_not_inherit))
            assert_equal(Hash[key => "value"], DependencyInjection.normalize_selection(key => "value"))
            assert_equal(Hash[key => key], DependencyInjection.normalize_selection(key => key))
        end

        def test_normalize_selection_refuses_component_to_data_service
            key = Component.new_submodel
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => DataService.new_submodel) }
        end

        def test_normalize_selection_accepts_component_to_component_that_fullfill_the_key
            srv = DataService.new_submodel
            key = Component.new_submodel
            subcomponent = key.new_submodel
            subcomponent.provides srv, as: "srv"

            assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent))
            subcomponent = subcomponent.new
            assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent))
        end

        def test_normalize_selection_accepts_component_to_instance_requirements_that_fullfill_the_key
            key = Component.new_submodel
            req = InstanceRequirements.new([key])
            assert_equal(Hash[key => req], DependencyInjection.normalize_selection(key => req))
        end

        def test_normalize_selection_rejects_component_to_component_that_does_not_fullfill_the_key
            key = Component.new_submodel
            srv = DataService.new_submodel
            component = Component.new_submodel { provides(srv, as: "srv") }

            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component) }
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component.srv_srv) }
            component = component.new
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component) }
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component.srv_srv) }
        end

        def test_normalize_selection_rejects_component_to_instance_requirements_that_fullfill_the_key
            key = Component.new_submodel
            req = InstanceRequirements.new([Component.new_submodel])
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => req) }
        end

        def test_normalize_selection_accepts_data_service_to_string_nil_and_identity
            key = DataService.new_submodel
            assert_equal(Hash[key => DependencyInjection.nothing], DependencyInjection.normalize_selection(key => DependencyInjection.nothing))
            assert_equal(Hash[key => DependencyInjection.do_not_inherit], DependencyInjection.normalize_selection(key => DependencyInjection.do_not_inherit))
            assert_equal(Hash[key => "value"], DependencyInjection.normalize_selection(key => "value"))
            assert_equal(Hash[key => key], DependencyInjection.normalize_selection(key => key))
        end

        def test_normalize_selection_accepts_data_service_to_data_service_that_fullfill_the_key
            srv0 = DataService.new_submodel
            srv1 = DataService.new_submodel { provides srv0 }
            assert_equal(Hash[srv0 => srv1], DependencyInjection.normalize_selection(srv0 => srv1))
        end

        def test_normalize_selection_accepts_data_service_to_instance_requirements_that_fullfill_the_key
            key = DataService.new_submodel
            req = InstanceRequirements.new([key])
            assert_equal(Hash[key => req.find_data_service_from_type(key)], DependencyInjection.normalize_selection(key => req))
        end

        def test_normalize_selection_accepts_data_service_to_instance_requirements_that_fullfill_the_key_and_selects_the_corresponding_service
            key = DataService.new_submodel
            c = Component.new_submodel { provides key, as: "srv" }
            req = InstanceRequirements.new([c])
            normalized = DependencyInjection.normalize_selection(key => req)
            req_srv = req.dup
            req_srv.select_service(c.srv_srv)
            assert_equal(Hash[key => req_srv], normalized)
        end

        def test_normalize_selection_accepts_data_service_to_component_that_fullfill_the_key_and_maps_the_service
            srv0 = DataService.new_submodel
            c = Component.new_submodel { provides srv0, as: "srv" }
            assert_equal(Hash[srv0 => c.srv_srv], DependencyInjection.normalize_selection(srv0 => c))
            c = c.new
            assert_equal(Hash[srv0 => c.srv_srv], DependencyInjection.normalize_selection(srv0 => c))
        end

        def test_normalize_selection_rejects_data_service_to_instance_requirements_that_does_not_fullfill_the_key
            key = DataService.new_submodel
            req = InstanceRequirements.new([DataService.new_submodel])
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => req) }
        end

        def test_normalize_selection_rejects_data_service_to_component_that_has_multiple_matching_candidates
            srv0 = DataService.new_submodel
            c = Component.new_submodel do
                provides srv0, as: "srv0"
                provides srv0, as: "srv1"
            end
            assert_raises(Syskit::AmbiguousServiceSelection) { DependencyInjection.normalize_selection(srv0 => c) }
        end

        def test_normalize_selection_rejects_data_service_to_data_service_that_does_not_fullfill_the_key
            assert_raises(ArgumentError) { DependencyInjection.normalize_selection(DataService.new_submodel => DataService.new_submodel) }
        end

        def test_normalize_selection_converts_arbitrary_values_to_instance_requirements
            req = InstanceRequirements.new
            value = flexmock
            value.should_receive(:to_instance_requirements).once
                 .and_return(req)
            di = DependencyInjection.new
            di.add("name" => value)
            assert_same req, di.explicit["name"]
        end

        def test_resolve_default_selections_selects_all_models_fullfilled_by_a_component_model
            srv0 = DataService.new_submodel
            srv1 = DataService.new_submodel
            c = Component.new_submodel
            c.provides srv0, as: "srv0"
            c.provides srv1, as: "srv1"
            assert_equal(Hash[srv0 => c, srv1 => c, c => c, Syskit::AbstractComponent => c],
                         DependencyInjection.resolve_default_selections({}, [c]))
        end

        def test_resolve_default_selections_does_not_select_conflicting_defaults
            srv0 = DataService.new_submodel
            srv1 = DataService.new_submodel
            c0 = Component.new_submodel
            c0.provides srv0, as: "srv0"
            c0.provides srv1, as: "srv1"
            c1 = Component.new_submodel
            c1.provides srv0, as: "srv0"
            c2 = Component.new_submodel
            c2.provides srv0, as: "srv0"
            assert_equal(Hash[srv1 => c0, c0 => c0, c1 => c1, c2 => c2],
                         DependencyInjection.resolve_default_selections({}, [c0, c1, c2]))
        end

        def test_resolve_default_selections_does_not_override_explicit_selections
            srv0 = DataService.new_submodel
            c0 = Component.new_submodel
            c0.provides srv0, as: "srv0"
            assert_equal(Hash[srv0 => "value", c0 => c0, Syskit::AbstractComponent => c0],
                         DependencyInjection.resolve_default_selections(Hash[srv0 => "value"], [c0]))
        end

        def test_resolve_default_selections_applies_recursive_selection_before_resolving
            srv0 = DataService.new_submodel
            c0 = Component.new_submodel
            c1 = c0.new_submodel
            c1.provides srv0, as: "srv0"
            expected = Hash[srv0 => c1, c0 => c1, c1 => c1, Syskit::AbstractComponent => c1]
            assert_equal expected, DependencyInjection.resolve_default_selections(
                Hash[c0 => c1], [c0]
            )
        end

        def test_resolve_default_selections_ignores_services_provided_multiple_times
            srv_m = DataService.new_submodel name: "Srv"
            c_m = Component.new_submodel name: "Component"
            c_m.provides srv_m, as: "s0"
            c_m.provides srv_m, as: "s1"

            assert_equal Hash[c_m => c_m, Syskit::AbstractComponent => c_m],
                         DependencyInjection.resolve_default_selections({}, [c_m])
        end

        def test_find_name_resolution_plain_name
            c0 = Component.new_submodel
            assert_equal c0, DependencyInjection.find_name_resolution("name", "name" => c0)
        end

        def test_find_name_resolution_does_not_resolve_names_recursively
            c0 = Component.new_submodel
            assert !DependencyInjection.find_name_resolution("name", "name" => "value", "value" => c0)
        end

        def test_find_name_resolution_name_does_not_exist
            assert !DependencyInjection.find_name_resolution("name", {})
        end

        def test_find_name_resolution_name_resolves_to_nil
            DependencyInjection.find_name_resolution("name", "name" => nil)
        end

        def test_find_name_resolution_name_resolves_to_another_name
            DependencyInjection.find_name_resolution("name", "name" => "value")
        end

        def test_find_name_resolution_with_service
            c0 = Component.new_submodel
            srv = DataService.new_submodel
            c0.provides srv, as: "srv"
            assert_equal c0.srv_srv, DependencyInjection.find_name_resolution("name.srv", "name" => c0)
        end

        def test_find_name_resolution_with_service_raises_if_model_cannot_hold_services
            srv = DataService.new_submodel
            assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution("name.srv", "name" => srv) }
        end

        def test_find_name_resolution_with_service_raises_if_service_not_found
            c0 = Component.new_submodel
            assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution("name.srv", "name" => c0) }
        end

        def test_find_name_resolution_with_slave_service
            c0 = Component.new_submodel
            srv = DataService.new_submodel
            c0.provides srv, as: "srv"
            c0.provides srv, as: "slave", slave_of: "srv"
            assert_equal c0.srv_srv.slave_srv, DependencyInjection.find_name_resolution("name.srv.slave", "name" => c0)
        end

        def test_find_name_resolution_with_slave_service_raises_if_service_not_found
            c0 = Component.new_submodel
            srv = DataService.new_submodel
            c0.provides srv, as: "srv"
            assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution("name.srv.slave", "name" => c0) }
        end

        def test_resolve_names_does_not_change_non_names
            c0 = Component.new_submodel
            obj = DependencyInjection.new("name" => c0)
            obj.resolve_names
            assert_equal Hash["name" => c0], obj.explicit
        end

        def test_resolve_names_only_uses_provided_mappings
            c0 = Component.new_submodel
            obj = DependencyInjection.new("name" => "bla", "bla" => "blo")
            assert_equal %w{bla blo}.to_set, obj.resolve_names
            assert_equal %w{blo}.to_set, obj.resolve_names("bla" => c0)
        end

        def test_resolve_names_applies_on_explicit_and_defaults
            c0 = Component.new_submodel
            obj = DependencyInjection.new("test", "name" => "bla")
            flexmock(DependencyInjection).should_receive(:find_name_resolution)
                                         .with("bla", any).once.and_return(bla = Object.new)
            flexmock(DependencyInjection).should_receive(:find_name_resolution)
                                         .with("test", any).once.and_return(test = Object.new)
            assert_equal %w{}.to_set, obj.resolve_names
            assert_equal Hash["name" => bla], obj.explicit
            assert_equal [test].to_set, obj.defaults
        end

        def test_resolve_names_returns_unresolved_names
            c0 = Component.new_submodel
            obj = DependencyInjection.new("name" => "bla", "value" => "test")
            flexmock(DependencyInjection).should_receive(:find_name_resolution)
                                         .with("bla", any).once.and_return(nil)
            flexmock(DependencyInjection).should_receive(:find_name_resolution)
                                         .with("test", any).once.and_return(sel = Object.new)
            assert_equal %w{bla}.to_set, obj.resolve_names
        end

        def test_selection_for_calls_resolve_if_needed
            c0 = Component.new_submodel
            di = DependencyInjection.new("value" => c0)
            flexmock(di).should_receive(:resolve).never
            di.selection_for("value", InstanceRequirements.new)

            c1 = Component.new_submodel
            req = InstanceRequirements.new
            resolved_di = flexmock
            di = DependencyInjection.new(c1, "value" => c0)
            flexmock(di).should_receive(:resolve).once.and_return(resolved_di)
            flexmock(resolved_di).should_receive(:selection_for).once.with("name", req).and_return(obj = Object.new)
            assert_equal obj, di.selection_for("name", req)
        end

        def test_selection_for_component_to_component
            c0 = Component.new_submodel
            c1 = c0.new_submodel
            di = DependencyInjection.new(c0 => c1)
            assert_equal [nil, InstanceRequirements.new([c1]), {}, [c0].to_set],
                         di.selection_for(nil, InstanceRequirements.new([c0]))
        end

        def test_selection_for_data_services_to_component_maps_services
            srv = DataService.new_submodel
            c0 = Component.new_submodel { provides srv, as: "srv" }
            di = DependencyInjection.new(srv => c0)
            assert_equal [nil, InstanceRequirements.new([c0]), { srv => c0.srv_srv }, [srv].to_set],
                         di.selection_for(nil, InstanceRequirements.new([srv]))
        end

        def test_selection_for_data_services_to_composite_model_without_proxy
            srv = DataService.new_submodel name: "Srv"
            c0 = Component.new_submodel(name: "C0") { provides srv, as: "srv" }
            c1 = c0.new_submodel(name: "C1")
            di = DependencyInjection.new(c0 => c1, srv => c0)

            task, requirements, service_mappings, used_keys =
                di.selection_for(nil, InstanceRequirements.new([srv]))
            assert !task
            assert_equal c1, requirements.model
            assert_equal Hash[srv => c1.srv_srv], service_mappings
            assert_equal [srv].to_set, used_keys
        end

        def test_selection_for_data_services_fails_with_incompatible_composite_model_with_proxy
            srv = DataService.new_submodel name: "Srv"
            c0 = TaskContext.new_submodel(name: "C0")
            c1 = TaskContext.new_submodel(name: "C1") { provides srv, as: "srv" }
            di = DependencyInjection.new(srv => c1)

            assert_raises(IncompatibleComponentModels) { di.selection_for(nil, InstanceRequirements.new([c0, srv])) }
        end

        def test_map_bang
            req = DependencyInjection.new("value2", "test" => "value")
            req.map!(&:upcase)
            assert_equal Hash["test" => "VALUE"], req.explicit
            assert_equal Set["VALUE2"], req.defaults
        end

        def test_select_bound_service_using_instance_requirements
            srv_m = Syskit::DataService.new_submodel
            task_m = Syskit::TaskContext.new_submodel do
                provides srv_m, as: "s0"
                provides srv_m, as: "s1"
            end
            di = DependencyInjection.new(srv_m => task_m.s0_srv.to_instance_requirements)
            di.instance_selection_for(nil, srv_m.to_instance_requirements)
        end
    end
end
