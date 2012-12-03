require 'simplecov'
require 'syskit'
require 'syskit/test'

class TC_DependencyInjection < Test::Unit::TestCase
    include Syskit::SelfTest

    def test_to_s
        # Just checking that it does not raise and returns a string
        di = DependencyInjection.new('val', 'name' => 'value')
        assert_respond_to di.to_s, :to_s
    end

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

    def test_add_dependency_injection
        di = DependencyInjection.new('val', 'name' => 'value')
        new_di = flexmock(DependencyInjection.new)
        new_di.should_receive(:add_explicit).with(di.explicit).once
        new_di.should_receive(:add_defaults).with(di.defaults).once
        new_di.add(di)
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

    def test_normalize_selection_accepts_string_to_allowed_values
        srv = DataService.new_submodel
        component = Component.new_submodel
        component.provides srv, :as => 'srv'
        key = 'key'
        assert_equal(Hash[key => nil], DependencyInjection.normalize_selection(key => nil))
        assert_equal(Hash[key => 'value'], DependencyInjection.normalize_selection(key => 'value'))
        assert_equal(Hash[key => srv], DependencyInjection.normalize_selection(key => srv))
        assert_equal(Hash[key => component], DependencyInjection.normalize_selection(key => component))
        assert_equal(Hash[key => component.srv_srv], DependencyInjection.normalize_selection(key => component.srv_srv))
        req = InstanceRequirements.new
        assert_equal(Hash[key => req], DependencyInjection.normalize_selection(key => req))
    end

    def test_normalize_selection_rejects_string_to_arbitrary
        key = 'key'
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => Object.new) }
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

    def test_normalize_selection_rejects_string_to_arbitrary
        key = Component.new_submodel
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => Object.new) }
    end

    def test_normalize_selection_refuses_component_to_data_service
        key = Component.new_submodel
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => DataService.new_submodel) }
    end

    def test_normalize_selection_accepts_component_to_component_that_fullfill_the_key
        srv = DataService.new_submodel
        key = Component.new_submodel
        subcomponent = key.new_submodel
        subcomponent.provides srv, :as => 'srv'

        assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent))
        assert_equal(Hash[key => subcomponent], DependencyInjection.normalize_selection(key => subcomponent.srv_srv))
    end

    def test_normalize_selection_accepts_component_to_instance_requirements_that_fullfill_the_key
        key = Component.new_submodel
        req = InstanceRequirements.new([key])
        assert_equal(Hash[key => req], DependencyInjection.normalize_selection(key => req))
    end

    def test_normalize_selection_rejects_component_to_component_that_does_not_fullfill_the_key
        key = Component.new_submodel
        srv = DataService.new_submodel
        component = Component.new_submodel { provides(srv, :as => 'srv') }
        
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
        assert_equal(Hash[key => nil], DependencyInjection.normalize_selection(key => nil))
        assert_equal(Hash[key => 'value'], DependencyInjection.normalize_selection(key => 'value'))
        assert_equal(Hash[key => key], DependencyInjection.normalize_selection(key => key))
    end

    def test_normalize_selection_rejects_string_to_arbitrary
        key = DataService.new_submodel
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => Object.new) }
    end

    def test_normalize_selection_accepts_data_service_to_data_service_that_fullfill_the_key
        srv0 = DataService.new_submodel
        srv1 = DataService.new_submodel { provides srv0 }
        assert_equal(Hash[srv0 => srv1], DependencyInjection.normalize_selection(srv0 => srv1))
    end

    def test_normalize_selection_accepts_data_service_to_instance_requirements_that_fullfill_the_key
        key = DataService.new_submodel
        req = InstanceRequirements.new([key])
        assert_equal(Hash[key => req], DependencyInjection.normalize_selection(key => req))
    end

    def test_normalize_selection_accepts_data_service_to_component_that_fullfill_the_key_and_maps_the_service
        srv0 = DataService.new_submodel
        c = Component.new_submodel { provides srv0, :as => 'srv' }
        assert_equal(Hash[srv0 => c.srv_srv], DependencyInjection.normalize_selection(srv0 => c))
    end

    def test_normalize_selection_rejects_data_service_to_instance_requirements_that_fullfill_the_key
        key = DataService.new_submodel
        req = InstanceRequirements.new([DataService.new_submodel])
        assert_raises(ArgumentError) { DependencyInjection.normalize_selection(key => req) }
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
        c2 = Component.new_submodel
        c2.provides srv0, :as => 'srv0'
        assert_equal(Hash[srv1 => c0, c0 => c0, c1 => c1, c2 => c2], DependencyInjection.resolve_default_selections(Hash.new, [c0, c1, c2]))
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

    def test_find_name_resolution_plain_name
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

    def test_resolve_names_does_not_change_non_names
        c0 = Component.new_submodel
        obj = DependencyInjection.new('name' => c0)
        obj.resolve_names
        assert_equal Hash['name' => c0], obj.explicit
    end

    def test_resolve_names_only_uses_provided_mappings
        c0 = Component.new_submodel
        obj = DependencyInjection.new('name' => 'bla', 'bla' => 'blo')
        assert_equal %w{bla blo}.to_set, obj.resolve_names
        assert_equal %w{blo}.to_set, obj.resolve_names('bla' => c0)
    end

    def test_resolve_names_applies_on_explicit_and_defaults
        c0 = Component.new_submodel
        obj = DependencyInjection.new('test', 'name' => 'bla')
        flexmock(DependencyInjection).should_receive(:find_name_resolution).
            with('bla', any).once.and_return(bla = Object.new)
        flexmock(DependencyInjection).should_receive(:find_name_resolution).
            with('test', any).once.and_return(test = Object.new)
        assert_equal %w{}.to_set, obj.resolve_names
        assert_equal Hash['name' => bla], obj.explicit
        assert_equal [test].to_set, obj.defaults
    end

    def test_resolve_names_returns_unresolved_names
        c0 = Component.new_submodel
        obj = DependencyInjection.new('name' => 'bla', 'value' => 'test')
        flexmock(DependencyInjection).should_receive(:find_name_resolution).
            with('bla', any).once.and_return(nil)
        flexmock(DependencyInjection).should_receive(:find_name_resolution).
            with('test', any).once.and_return(sel = Object.new)
        assert_equal %w{bla}.to_set, obj.resolve_names
    end

    def test_resolve_names_recursively_applies_on_instance_requirements
        requirements = flexmock(Syskit::InstanceRequirements.new)
        requirements.should_receive(:resolve_names).and_return(Set.new).once
        obj = DependencyInjection.new('name' => requirements)
        obj.resolve_names
    end

    def test_resolve_names_recursively_applies_on_instance_requirements_using_the_same_mappings
        mappings = Hash.new
        requirements = flexmock(Syskit::InstanceRequirements.new)
        requirements.should_receive(:resolve_names).and_return(Set.new).with(mappings).once
        obj = DependencyInjection.new('name' => requirements)
        obj.resolve_names(mappings)
    end

    def test_resolve_names_returns_unresolved_names_from_recursive_instance_requirements
        requirements = flexmock(Syskit::InstanceRequirements.new)
        requirements.should_receive(:resolve_names).and_return(['unresolved_name'])
        obj = DependencyInjection.new('name' => requirements, 'another_name' => 'bla')
        assert_equal %w{unresolved_name bla}.to_set, obj.resolve_names
    end

    def test_component_model_for_calls_resolve_if_needed
        c0 = Component.new_submodel
        di = DependencyInjection.new('value' => c0)
        flexmock(di).should_receive(:resolve).never
        di.component_model_for('value', InstanceRequirements.new)

        c1 = Component.new_submodel
        req = InstanceRequirements.new
        resolved_di = flexmock
        di = DependencyInjection.new(c1, 'value' => c0)
        flexmock(di).should_receive(:resolve).once.and_return(resolved_di)
        flexmock(resolved_di).should_receive(:component_model_for).once.with('name', req).and_return(obj = Object.new)
        assert_equal obj, di.component_model_for('name', req)
    end

    def test_component_model_for_component_to_component
        c0 = Component.new_submodel
        c1 = c0.new_submodel
        di = DependencyInjection.new(c0 => c1)
        assert_equal [c1, Hash.new], di.component_model_for(nil, InstanceRequirements.new([c0]))
    end

    def test_component_model_for_data_services_to_component_maps_services
        srv = DataService.new_submodel
        c0 = Component.new_submodel { provides srv, :as => 'srv' }
        di = DependencyInjection.new(srv => c0)
        assert_equal [c0, {srv => c0.srv_srv}], di.component_model_for(nil, InstanceRequirements.new([srv]))
    end

    def test_component_model_for_data_services_to_composite_model_without_proxy
        srv = DataService.new_submodel :name => 'Srv'
        c0 = Component.new_submodel(:name => 'C0') { provides srv, :as => 'srv' }
        c1 = c0.new_submodel(:name => 'C1')
        di = DependencyInjection.new(c0 => c1, srv => c0)
        assert_equal [c1, {srv => c1.srv_srv}], di.component_model_for(nil, InstanceRequirements.new([srv]))
    end

    def test_component_model_for_data_services_to_composite_model_with_proxy
        srv = DataService.new_submodel :name => 'Srv'
        c0 = TaskContext.new_submodel(:name => 'C0')
        c1 = c0.new_submodel(:name => 'C1')
        di = DependencyInjection.new(c0 => c1)

        model, mappings = di.component_model_for(nil, InstanceRequirements.new([c0, srv]))
        assert_equal c1, model.superclass
        assert_equal [srv].to_set, model.proxied_data_services
        assert_equal [c1, srv], model.fullfilled_model.to_a
    end

    def test_component_model_for_data_services_to_composite_model_with_proxy
        srv = DataService.new_submodel :name => 'Srv'
        c0 = TaskContext.new_submodel(:name => 'C0')
        c1 = TaskContext.new_submodel(:name => 'C1') { provides srv, :as => 'srv' }
        di = DependencyInjection.new(srv => c1)

        assert_raises(IncompatibleComponentModels) { di.component_model_for(nil, InstanceRequirements.new([c0, srv])) }
    end
end


