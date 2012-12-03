require 'syskit'
require 'syskit/test'

class TC_DependencyInjection < Test::Unit::TestCase
    include Syskit::SelfTest

    def test_new_object_with_initial_selection
        component_model = Component.new_submodel
        dep = DependencyInjection.new(component_model, 'name' => 'value')
        assert_equal({"name" => "value"}, dep.explicit)
        assert_equal [component_model], dep.defaults.to_a
    end

    def test_new_object_is_empty
        dep = DependencyInjection.new
        assert dep.empty?
    end

    def test_cleared_object_is_empty
        dep = DependencyInjection.new
        dep.add 'name' => 'value'
        dep.clear
        assert dep.empty?
    end

    def test_adding_explicit_selection_makes_the_object_not_empty
        dep = DependencyInjection.new
        dep.add 'name' => 'value'
        assert !dep.empty?
    end

    def test_adding_implicit_selection_makes_the_object_not_empty
        dep = DependencyInjection.new
        dep.add Component.new_submodel
        assert !dep.empty?
    end

    def test_pretty_print
        dep = DependencyInjection.new(Component.new_submodel, DataService.new_submodel => 'value')
        # Just verify that it does not raise ...
        PP.pp(dep, "")
    end

    def test_resolve_recursive_selection_mapping
        srv0 = DataService.new_submodel
        srv1 = DataService.new_submodel
        srv1.provides srv0
        mapping = { 'name' => 'value', 'value' => srv0, srv0 => srv1 }
        assert_equal({ 'name' => 'value', 'value' => srv1, srv0 => srv1 },
            DependencyInjection.resolve_recursive_selection_mapping(mapping))
    end

    def test_normalize_selection_raises_on_invalid_keys
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(nil => 'value') }
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(Object.new => 'value') }
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(Class.new => 'value') }
    end

    def test_normalize_selection_accepts_string_to_any
        srv = DataService.new_submodel
        component = Component.new_submodel
        component.provides srv, :as => 'srv'
        key = 'key'
        assert_equal(Hash[key => nil], DependencyInjection.normalize_selection(key => nil))
        assert_equal(Hash[key => 'value'], DependencyInjection.normalize_selection(key => 'value'))
        assert_equal(Hash[key => srv], DependencyInjection.normalize_selection(key => srv))
        assert_equal(Hash[key => component], DependencyInjection.normalize_selection(key => component))
        assert_equal(Hash[key => component.srv_srv], DependencyInjection.normalize_selection(key => component.srv_srv))
    end

    def test_normalize_selection_accepts_component_to_nil_string_and_identity
        srv = DataService.new_submodel
        component = Component.new_submodel
        component.provides srv, :as => 'srv'
        key = component
        
        assert_equal(Hash[key => nil], DependencyInjection.normalize_selection(key => nil))
        assert_equal(Hash[key => 'value'], DependencyInjection.normalize_selection(key => 'value'))
        assert_equal(Hash[key => key], DependencyInjection.normalize_selection(key => key))
    end

    def test_normalize_selection_refuses_component_to_data_service
        key = Component.new_submodel
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => DataService.new_submodel) }
    end

    def test_normalize_selection_accepts_component_that_fullfill_the_key
        srv = DataService.new_submodel
        key = Component.new_submodel
        subcomponent = key.new_submodel
        subcomponent.provides srv, :as => 'srv'

        assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent))
        assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent.srv_srv))
    end

    def test_normalize_selection_rejects_component_that_does_not_fullfill_the_key
        key = Component.new_submodel
        srv = DataService.new_submodel
        component = Component.new_submodel { provides(srv, :as => 'srv') }
        
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component) }
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => component.srv_srv) }
    end

    def test_normalize_selection_accepts_data_service_to_string_nil_and_identity
        key = DataService.new_submodel
        assert_equal(Hash[key => nil], DependencyInjection.normalize_selection(key => nil))
        assert_equal(Hash[key => 'value'], DependencyInjection.normalize_selection(key => 'value'))
        assert_equal(Hash[key => key], DependencyInjection.normalize_selection(key => key))
    end

    def test_normalize_selection_accepts_data_service_to_data_service_that_fullfill_the_key
        srv0 = DataService.new_submodel
        srv1 = DataService.new_submodel { provides srv0 }
        assert_equal(Hash[srv0 => srv1], DependencyInjection.normalize_selection(srv0 => srv1))
    end

    def test_normalize_selection_accepts_data_service_to_component_that_fullfill_the_key_and_maps_the_service
        srv0 = DataService.new_submodel
        c = Component.new_submodel { provides srv0, :as => 'srv' }
        assert_equal(Hash[srv0 => c.srv_srv], DependencyInjection.normalize_selection(srv0 => c))
    end

    def test_normalize_selection_rejects_data_service_to_component_that_has_multiple_matching_candidates
        srv0 = DataService.new_submodel
        c = Component.new_submodel do
            provides srv0, :as => 'srv0'
            provides srv0, :as => 'srv1'
        end
        assert_raises(Syskit::AmbiguousServiceSelection) { DependencyInjection.normalize_selection(srv0 => c) }
    end

    def test_normalize_selection_rejects_data_service_to_data_service_that_does_not_fullfill_the_key
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(DataService.new_submodel => DataService.new_submodel) }
    end

    def test_resolve_default_selections_selects_all_models_fullfilled_by_a_component_model
        srv0 = DataService.new_submodel
        srv1 = DataService.new_submodel
        c = Component.new_submodel
        c.provides srv0, :as => 'srv0'
        c.provides srv1, :as => 'srv1'
        assert_equal(Hash[srv0 => c, srv1 => c, c => c], DependencyInjection.resolve_default_selections(Hash.new, [c]))
    end

    def test_resolve_default_selections_does_not_select_conflicting_defaults
        srv0 = DataService.new_submodel
        srv1 = DataService.new_submodel
        c0 = Component.new_submodel
        c0.provides srv0, :as => 'srv0'
        c0.provides srv1, :as => 'srv1'
        c1 = Component.new_submodel
        c1.provides srv0, :as => 'srv0'
        assert_equal(Hash[srv1 => c0, c0 => c0, c1 => c1], DependencyInjection.resolve_default_selections(Hash.new, [c0, c1]))
    end

    def test_resolve_default_selections_does_not_override_explicit_selections
        srv0 = DataService.new_submodel
        c0 = Component.new_submodel
        c0.provides srv0, :as => 'srv0'
        assert_equal(Hash[srv0 => 'value', c0 => c0], DependencyInjection.resolve_default_selections(Hash[srv0 => 'value'], [c0]))
    end

    def test_resolve_default_selections_applies_recursive_selection_before_resolving
        srv0 = DataService.new_submodel
        c0 = Component.new_submodel
        c1 = c0.new_submodel
        c1.provides srv0, :as => 'srv0'
        assert_equal(Hash[srv0 => c1, c0 => c1, c1 => c1], DependencyInjection.resolve_default_selections(Hash[c0 => c1], [c0]))
    end

    def test_resolve_name_plain
        c0 = Component.new_submodel
        assert_equal c0, DependencyInjection.find_name_resolution('name', 'name' => c0)
    end

    def test_find_name_resolution_does_not_resolve_names_recursively
        c0 = Component.new_submodel
        assert !DependencyInjection.find_name_resolution('name', 'name' => 'value', 'value' => c0)
    end

    def test_find_name_resolution_name_does_not_exist
        assert !DependencyInjection.find_name_resolution('name', Hash.new)
    end

    def test_find_name_resolution_name_resolves_to_nil
        DependencyInjection.find_name_resolution('name', 'name' => nil)
    end

    def test_find_name_resolution_name_resolves_to_another_name
        DependencyInjection.find_name_resolution('name', 'name' => 'value')
    end

    def test_find_name_resolution_with_service
        c0 = Component.new_submodel
        srv = DataService.new_submodel
        c0.provides srv, :as => 'srv'
        assert_equal c0.srv_srv, DependencyInjection.find_name_resolution('name.srv', 'name' => c0)
    end

    def test_find_name_resolution_with_service_raises_if_model_cannot_hold_services
        srv = DataService.new_submodel
        assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution('name.srv', 'name' => srv) }
    end

    def test_find_name_resolution_with_service_raises_if_service_not_found
        c0 = Component.new_submodel
        assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution('name.srv', 'name' => c0) }
    end

    def test_find_name_resolution_with_slave_service
        c0 = Component.new_submodel
        srv = DataService.new_submodel
        c0.provides srv, :as => 'srv'
        c0.provides srv, :as => 'slave', :slave_of => 'srv'
        assert_equal c0.srv_srv.slave_srv, DependencyInjection.find_name_resolution('name.srv.slave', 'name' => c0)
    end

    def test_find_name_resolution_with_slave_service_raises_if_service_not_found
        c0 = Component.new_submodel
        srv = DataService.new_submodel
        c0.provides srv, :as => 'srv'
        assert_raises(Syskit::NameResolutionError) { DependencyInjection.find_name_resolution('name.srv.slave', 'name' => c0) }
    end

    def test_resolve_names_only_uses_provided_mappings
        c0 = Component.new_submodel
        obj = DependencyInjection.new('name' => 'bla', 'bla' => 'blo')
        assert_equal %w{bla blo}.to_set, obj.resolve_names
        assert_equal %w{blo}.to_set, obj.resolve_names('bla' => c0)
    end

    def test_resolve_names_applies_on_explicit_and_defaults
    end

    def test_resolve_names_returns_unresolved_names
    end

    def test_resolve_names_recursively_applies_on_instance_requirements
    end

    def test_resolve_names_recursively_applies_on_instance_requirements_not_using_subobject_explicit_mappings
    end

    def test_resolve_names_returns_unresolved_names_from_recursive_instance_requirements
    end

    def test_resolve_multiple_selections_needing_proxy
    end

    def test_resolve_multiple_selections_maps_services
    end

    def test_resolve_multiple_selections_incompatible_models
    end

    def test_resolve_multiple_selections_with_explicit_service_selections
    end

    def test_instance_selection_for_by_name_component
    end

    def test_instance_selection_for_by_name_data_service
    end

    def test_instance_selection_for_by_name_bound_data_service
    end

    def test_remove_unresolved
    end
end


