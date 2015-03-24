require 'minitest/autorun'
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
        include Roby::Test::Self
        include Test::Base
        include Test::NetworkManipulation

        # The syskit engine
        attr_reader :syskit_engine
        # A RobotDefinition object that allows to create new device models
        # easily
        attr_reader :robot


        def data_dir
            File.join(SYSKIT_ROOT_DIR, "test", "data")
        end

        def setup
            @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
            Roby.app.app_dir = nil
            Roby.app.search_path.clear
            ENV['ROBY_PLUGIN_PATH'] = File.expand_path(File.join(File.dirname(__FILE__), '..', 'roby_app', 'register_plugin.rb'))
            Roby.app.using 'syskit'
            Syskit.conf.export_types = false
            Syskit.conf.disables_local_process_server = true
            Syskit.conf.only_load_models = true

            super

            if !Orocos.initialized?
                Orocos.initialize
            end
            engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

            Syskit::NetworkGeneration::Engine.keep_internal_data_structures = true

            @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
            @robot = Syskit::Robot::RobotDefinition.new

            @syskit_handler_ids = Array.new
            @syskit_handler_ids << engine.add_propagation_handler(:type => :external_events, &Runtime.method(:update_deployment_states))
            @syskit_handler_ids << engine.add_propagation_handler(:type => :external_events, &Runtime.method(:update_task_states))
            @syskit_handler_ids << engine.add_propagation_handler(:type => :propagation, :late => true, &Runtime::ConnectionManagement.method(:update))

            if !Syskit.conf.disables_local_process_server?
                Syskit::RobyApp::Plugin.connect_to_local_process_server
            end
        end

        def teardown
            ENV['PKG_CONFIG_PATH'] = @old_pkg_config
            if syskit_engine
                syskit_engine.finalize
            end
            super

        ensure
            if @syskit_handler_ids
                Syskit::RobyApp::Plugin.unplug_engine_from_roby(@syskit_handler_ids, engine)
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

        def method_missing(m, *args, &block)
            if syskit_engine.respond_to?(m)
                syskit_engine.send(m, *args, &block)
            else super
            end
        end
    end
    end
end

module Minitest
    class Test
        include Syskit::Test::Self
    end
end





