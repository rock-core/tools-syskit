require 'syskit/test'

class TC_AbstractPlaceholders < Test::Unit::TestCase
    include Syskit::SelfTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_proxy_simple_task_context
	task_model = Component.new_submodel
	proxy = Syskit.proxy_task_model_for([task_model])
	assert_kind_of(task_model, proxy)
    end

    def test_proxy_data_services
	services = [
	    data_service_type('B'),
	    data_service_type('A'),
	    data_service_type('C')
	]
	proxy = Syskit.proxy_task_model_for(services)
	assert(proxy.abstract?)
	assert_equal('Syskit::PlaceholderTask<A,B,C>', proxy.name)
	assert_equal(services.to_set, proxy.proxied_data_services.to_set)
	assert_equal(services.to_set, proxy.fullfilled_model[1].to_set)
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end

    def test_proxy_task_and_data_service_mix
	# TODO: task_model should be allowed to be any component model
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
	assert_same(task_model, proxy.fullfilled_model[0])
	assert_equal(services.to_set, proxy.fullfilled_model[1].to_set)
	assert(proxy.fullfills?(task_model))
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end
end

