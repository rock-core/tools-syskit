# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['SYSKIT_ENABLE_COVERAGE'] == '1' || ENV['SYSKIT_ENABLE_COVERAGE'] == '2'
    begin
        require 'simplecov'
        if ENV['SYSKIT_ENABLE_COVERAGE'] == '2'
            require 'syskit'
            Syskit.warn "coverage has been automatically enabled, which has a noticeable effect on runtime"
            Syskit.warn "Set SYSKIT_ENABLE_COVERAGE=0 in your shell to disable"
        end

    rescue LoadError
        require 'syskit'
        Syskit.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
    rescue Exception => e
        require 'syskit'
        Syskit.warn "coverage is disabled: #{e.message}"
    end
end

require 'syskit'
require 'roby'
require 'roby/test/common'
require 'roby/schedulers/temporal'
require 'orocos/ruby_process_server'

require 'test/unit'
require 'flexmock/test_unit'
require 'minitest/spec'

if ENV['SYSKIT_ENABLE_PRY'] != '0'
    begin
        require 'pry'
    rescue Exception
        Syskit.warn "debugging is disabled because the 'pry' gem cannot be loaded"
    end
end

module Syskit
        module Test
            include Syskit
	    include Roby::Test
	    include Roby::Test::Assertions
            include FlexMock::ArgumentTypes
            include FlexMock::MockContainer

            # The syskit engine
            attr_reader :syskit_engine
            # A RobotDefinition object that allows to create new device models
            # easily
            attr_reader :robot

            def prepare_plan(options)
                result = super

                options, _ = Kernel.filter_options options, :model => nil
                if options[:model] && options[:model].respond_to?(:should_receive)
                    # The caller provided a mock class, give him a mock object
                    result.map do |obj|
                        if obj.respond_to?(:each)
                            obj.map do |instance|
                                mock_roby_task_context(instance)
                            end
                        else
                            mock_roby_task_context(obj)
                        end
                    end
                else
                    result
                end
            end

            def stub_roby_task_context(name = "task", task_model = nil, &block)
                task_model ||= TaskContext.new_submodel(&block)
                plan.add(task = task_model.new)
                task
            end

            def stub_roby_deployment_model(task_model, name = task_model.name)
                orogen_model = Orocos::Spec::Deployment.new(Orocos.master_project, name)
                orogen_model.task name, task_model.orogen_model
                model = Deployment.new_submodel(:orogen_model => orogen_model)
                Syskit.conf.deployments['localhost'] << model
                model
            end

            def stub_syskit_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= Deployment.new_submodel(:name => name, &block)
                Syskit.process_servers['stubs'].first.
                    register_deployment_model(deployment_model.orogen_model)
                plan.add(task = deployment_model.new(:on => 'stubs'))
                task
            end

            def stub_deployed_task(name = 'task', task = nil, &block)
                if !task || task.kind_of?(Class)
                    task = stub_roby_task_context(name, task, &block)
                end
                task.orocos_name ||= name
                deployment = stub_syskit_deployment("deployment_#{name}") do
                    task name, task.model.orogen_model
                end
                task.executed_by deployment
                deployment.start!
                task
            end

            def deploy_and_start_task_context(name, task)
                task = stub_deployed_task(name, task)
                start_task_context(task)
                task
            end

            def start_task_context(task)
                task.arguments[:conf] ||= []
                task.setup
                task.start!
                assert_event_emission task.start_event
            end

            def setup
                Roby.app.app_dir = nil
                Roby.app.search_path.clear
                @task_stubs = Array.new

                @old_loglevel = Orocos.logger.level
                Roby.app.using 'syskit'
                Roby.app.filter_backtraces = false
                Syskit.process_servers['stubs'] = [Orocos::RubyProcessServer.new, ""]

                super

                engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

                @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(engine)
		if !Syskit.conf.disables_local_process_server?
                    Syskit::RobyApp::Plugin.connect_to_local_process_server
		end

                @robot = Syskit::Robot::RobotDefinition.new
            end

            def teardown
                flexmock_teardown

                super

                if plan
                    deployments = plan.find_tasks(Deployment).running.to_a
                    deployments.each do |task|
                        if task.orocos_process.alive?
                            task.orocos_process.kill
                        end
                    end
                end

                @task_stubs.each do |t|
                    t.dispose
                end

            ensure
                if @handler_ids
                    Syskit::RobyApp::Plugin.unplug_engine_from_roby(@handler_ids, engine)
                end

                ENV['PKG_CONFIG_PATH'] = @old_pkg_config
                Orocos.logger.level = @old_loglevel if @old_loglevel
            end

            def method_missing(m, *args, &block)
                if syskit_engine.respond_to?(m)
                    syskit_engine.send(m, *args, &block)
                else super
                end
            end

            attr_predicate :keep_logs?, true

            def deploy(base_task = nil, resolve_options = Hash.new, &block)
                if engine.running?
                    execute do
                        syskit_engine.redeploy
                    end
                    engine.wait_one_cycle
                else
                    syskit_engine.disable_updates
                    if base_task && !base_task.planning_task.running?
                        base_task.planning_task.start!
                    end
                    syskit_engine.enable_updates
                    syskit_engine.resolve(resolve_options)
                end
                if block_given?
                    execute(&block)
                end
            end

            def assert_event_command_failed(expected_code_error = nil)
                begin
                    yield
                    flunk("expected Roby::CommandFailed, but no exception was raised")
                rescue Roby::CommandFailed => e
                    if !e.error.kind_of?(expected_code_error)
                        flunk("expected a Roby::CommandFailed wrapping #{expected_code_error}, but \"#{e.error}\" (#{e.error.class}) was raised")
                    end
                rescue Exception => e
                    flunk("expected Roby::CommandFailed, but #{e} was raised")
                end
            end

            def assert_deployable_orocos_subplan(root_task)
                requirements = []
                if root_task.respond_to?(:to_str)
                    requirements << root_task
                elsif root_task.respond_to?(:as_plan)
                    plan.add(root_task = root_task.as_plan)

                    Roby::TaskStructure::Dependency.each_bfs(root_task, BGL::Graph::ALL) do |from, to, info, kind|
                        planner = to.planning_task
                        if planner.kind_of?(InstanceRequirementsTask)
                            requirements << planner.arguments[:name]
                        end
                    end
                end

                # Do a copy of the currently loaded instances in the engine.
                current_instances = syskit_engine.instances.dup
                requirements.each do |req_name|
                    syskit_engine.clear
                    syskit_engine.instances.concat(current_instances)
                    syskit_engine.add(req_name)
                    
                    this = Time.now
                    gc = GC.count
                    GC::Profiler.clear
                    GC::Profiler.enable
                    syskit_engine.resolve
                    puts "resolved #{req_name} in #{Time.now - this} seconds (ran GC #{GC.count - gc} times)"
                    puts GC::Profiler.result
                    GC::Profiler.disable
                end

            ensure
                if current_instances
                    syskit_engine.clear
                    syskit_engine.instances.concat(instances)
                end
            end

            def instanciate_component(model)
                model.instanciate(plan, DependencyInjectionContext.new)
            end
        end

    module SelfTest
        include Test
        include Roby::SelfTest
        include FlexMock::ArgumentTypes
        include FlexMock::MockContainer

        def setup
            Roby.app.using 'syskit'
            Orocos.export_types = false
            Syskit.conf.disables_local_process_server = true

            super
            Syskit::NetworkGeneration::Engine.keep_internal_data_structures = true

            @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)

            if @handler_ids
                Syskit::RobyApp::Plugin.unplug_engine_from_roby(@handler_ids, engine)
                @handler_ids.clear
                @handler_ids << engine.add_propagation_handler(:type => :external_events, &Runtime.method(:update_deployment_states))
                @handler_ids << engine.add_propagation_handler(:type => :external_events, &Runtime.method(:update_task_states))
            end
        end

        def teardown
            if syskit_engine
                syskit_engine.finalize
            end
            super
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


