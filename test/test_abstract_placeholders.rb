require 'syskit/test'

class TC_AbstractPlaceholders < Test::Unit::TestCase
    include Syskit::SelfTest

    def test_proxy_simple_task_context
	task_model = TaskContext.new_submodel
	proxy_model = Syskit.proxy_task_model_for([task_model])
        assert_same proxy_model, task_model
    end

    def test_proxy_data_services
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services)
	assert(proxy.abstract?)
	assert_equal('Syskit::PlaceholderTask<Syskit::Component,A,B,C>', proxy.name)
	assert_equal(services.to_set, proxy.proxied_data_services.to_set)
	assert_equal(([Syskit::DataService] + services).to_set, proxy.fullfilled_model.to_set)
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end

    def test_proxy_task_and_data_service_mix
	task_model = Component.new_submodel
        task_model.name = "NewComponentModel"
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services + [task_model])
	assert(proxy.abstract?)
	assert(proxy < task_model)
        assert_not_same(proxy, task_model)
	assert_equal("Syskit::PlaceholderTask<#{task_model.name},A,B,C>", proxy.name)

	assert_equal(services.to_set, proxy.proxied_data_services.to_set)
	assert_equal(([task_model, Syskit::Component, Roby::Task, Syskit::DataService] + services).to_set, proxy.fullfilled_model.to_set)
	assert(proxy.fullfills?(task_model))
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end

    def test_proxy_tasks_are_registered_as_submodels
	task_model = TaskContext.new_submodel
	proxy_model = Syskit.proxy_task_model_for([data_service_type('A'), task_model])
        assert task_model.submodels.include?(proxy_model)
    end

    def test_proxy_task_returns_same_model
	task_model = TaskContext.new_submodel
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services + [task_model])
        assert_same proxy, Syskit.proxy_task_model_for(services.reverse + [task_model])
    end

    def test_proxy_task_returns_new_value_after_clear_submodels
	task_model = TaskContext.new_submodel
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services + [task_model])
        task_model.clear_submodels
        assert_not_same proxy, Syskit.proxy_task_model_for(services.reverse + [task_model])
    end

    def test_new_proxy_is_created_if_service_list_differs
	task_model = TaskContext.new_submodel
	services = [ data_service_type('B'), data_service_type('A'), data_service_type('C') ]
	proxy0 = Syskit.proxy_task_model_for(services + [task_model])

	services = [ data_service_type('B'), data_service_type('C') ]
        proxy1 = Syskit.proxy_task_model_for(services + [task_model])
        assert_not_same proxy0, proxy1
    end

    def test_clear_submodels_removes_cached_values
	task_model0 = TaskContext.new_submodel
	services0 = [ data_service_type('B'), data_service_type('A'), data_service_type('C') ]
	proxy0 = Syskit.proxy_task_model_for(services0 + [task_model0])

        task_model1 = TaskContext.new_submodel
	services1 = [ data_service_type('B'), data_service_type('C') ]
	proxy1 = Syskit.proxy_task_model_for(services1 + [task_model1])

        task_model0.clear_submodels
        assert_not_same proxy0, Syskit.proxy_task_model_for(services0 + [task_model0])
	assert_same proxy1, Syskit.proxy_task_model_for(services1 + [task_model1])
    end

    def test_proxy_task_can_use_anonymous_services
	task_model = TaskContext.new_submodel(:name => 'A')
	services = [DataService.new_submodel(:name => 'S')]
	proxy = Syskit.proxy_task_model_for(services + [task_model])
	assert(proxy.abstract?)
	assert(proxy < task_model)
        assert_not_same(proxy, task_model)
	assert_equal("Syskit::PlaceholderTask<A,S>", proxy.name)
    end

    def test_cannot_proxy_multiple_component_models_at_the_same_time
        task0 = TaskContext.new_submodel
        task1 = TaskContext.new_submodel
        assert_raises(ArgumentError) { Syskit.proxy_task_model_for([task0, task1]) }
    end

    def test_each_fullfilled_model_yields_real_task_model_as_well_as_proxied_services
	task_model = TaskContext.new_submodel
        task_model.name = "NewComponentModel"
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services + [task_model])
        assert_equal [task_model, Syskit::TaskContext, Syskit::Component, Roby::Task, Syskit::DataService, *services].to_set, proxy.each_fullfilled_model.to_set
    end
end

