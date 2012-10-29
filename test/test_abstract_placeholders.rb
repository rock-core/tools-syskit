BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobyPlugin_AbstractPlaceholder < Test::Unit::TestCase
    include RobyPluginCommonTest

    def setup
	Roby.app.using 'orocos'
	Roby.app.orocos_disables_local_process_server = true
	super
    end

    def test_proxy_simple_task_context
	task_model = Class.new(Component)
	proxy = Orocos::RobyPlugin.placeholder_model_for('simple_model', [task_model])
	assert_same(proxy, task_model)
    end

    def test_proxy_data_services
	services = [
	    sys_model.data_service_type('B'),
	    sys_model.data_service_type('A'),
	    sys_model.data_service_type('C')
	]
	proxy = Orocos::RobyPlugin.placeholder_model_for('data_services', services)
	assert(proxy.abstract?)
	assert_equal('data_services', proxy.name)
	assert_equal('Srv::A,Srv::B,Srv::C', proxy.short_name)
	assert_equal(services.to_set, proxy.proxied_data_services.to_set)
	assert_equal(services.to_set, proxy.fullfilled_model[1].to_set)
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end

    def test_proxy_task_and_data_service_mix
	# TODO: task_model should be allowed to be any component model
	task_model = mock_roby_task_context_model("a::task")
	services = [
	    sys_model.data_service_type('B'),
	    sys_model.data_service_type('A'),
	    sys_model.data_service_type('C')
	]
	proxy = Orocos::RobyPlugin.placeholder_model_for('mix', services + [task_model])
	assert(proxy.abstract?)
	assert(proxy < task_model)
        assert_not_same(proxy, task_model)
	assert_equal('mix', proxy.name)

	assert_equal(services.to_set, proxy.proxied_data_services.to_set)
	assert_same(task_model, proxy.fullfilled_model[0])
	assert_equal(services.to_set, proxy.fullfilled_model[1].to_set)
	assert(proxy.fullfills?(task_model))
	services.each do |srv|
	    assert(proxy.fullfills?(srv))
	end
    end
end

