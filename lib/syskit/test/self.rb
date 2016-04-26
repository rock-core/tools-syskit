require 'syskit/test/base'
require 'roby/test/self'
require 'syskit/test/network_manipulation'

module Syskit
    module Test
    # Module used in syskit's own test suite
    module Self
        include Syskit
        include Roby::Test
        include Roby::Test::Assertions
        include Test::Base
        include Test::NetworkManipulation

        # A RobotDefinition object that allows to create new device models
        # easily
        attr_reader :robot


        def data_dir
            File.join(SYSKIT_ROOT_DIR, "test", "data")
        end

        def app
            Roby.app
        end

        def setup
            @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
            Roby.app.app_dir = nil
            Roby.app.search_path.clear
            Roby.app.filter_backtraces = false
            ENV['ROBY_PLUGIN_PATH'] = File.expand_path(File.join(File.dirname(__FILE__), '..', 'roby_app', 'register_plugin.rb'))
            Roby.app.using 'syskit', force: true
            Syskit.conf.export_types = false
            Syskit.conf.disables_local_process_server = true
            Syskit.conf.only_load_models = true

            super

            if !Orocos.initialized?
                Orocos.initialize
            end
            execution_engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

            @robot = Syskit::Robot::RobotDefinition.new

            @syskit_handler_ids = Hash.new
            @syskit_handler_ids[:deployment_states] = execution_engine.
                add_propagation_handler(type: :external_events,
                                        &Runtime.method(:update_deployment_states))
            @syskit_handler_ids[:task_states] = execution_engine.
                add_propagation_handler(type: :external_events,
                                        &Runtime.method(:update_task_states))
            plug_connection_management
            unplug_apply_requirement_modifications

            if !Syskit.conf.disables_local_process_server?
                Syskit::RobyApp::Plugin.connect_to_local_process_server
            end

            Syskit.conf.register_process_server(
                'stubs', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")

        end

        def plug_apply_requirement_modifications
            @syskit_handler_ids[:apply_requirement_modifications] ||= execution_engine.
                add_propagation_handler(type: :propagation, late: true,
                                        &Runtime.method(:apply_requirement_modifications))
        end
        def unplug_apply_requirement_modifications
            execution_engine.remove_propagation_handler(@syskit_handler_ids.delete(:apply_requirement_modifications))
        end

        def plug_connection_management
            @syskit_handler_ids[:connection_management] ||= execution_engine.
                add_propagation_handler(type: :propagation, late: true,
                                        &Runtime::ConnectionManagement.method(:update))
        end
        def unplug_connection_management
            execution_engine.remove_propagation_handler(@syskit_handler_ids.delete(:connection_management))
        end

        def teardown
            plug_connection_management
            ENV['PKG_CONFIG_PATH'] = @old_pkg_config
            super

        ensure
            if @syskit_handler_ids && execution_engine
                Syskit::RobyApp::Plugin.unplug_engine_from_roby(@syskit_handler_ids.values, execution_engine)
            end
        end

        def assert_is_proxy_model_for(models, result)
            srv = nil
            proxied_models = Array(models).map do |m|
                if m.kind_of?(Syskit::Models::BoundDataService)
                    srv = m
                    m.component_model
                else m
                end
            end
            expected = Syskit.proxy_task_model_for(proxied_models)
            if srv
                expected = srv.attach(expected)
            end
            assert_equal expected, result, "#{result} was expected to be a proxy model for #{models} (#{expected})"
        end

        module ClassExtension
            def it(*args, &block)
                super(*args) do
                    begin
                        instance_eval(&block)
                    rescue Exception => e
                        if e.class.name =~ /Syskit|Roby/
                            pp e
                        end
                        raise
                    end
                end
            end
        end

        def data_service_type(name, &block)
            DataService.new_submodel(:name => name, &block)
        end
    end
    end
end

module Minitest
    class Test
        include Syskit::Test::Self
    end
end





