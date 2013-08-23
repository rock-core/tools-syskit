# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['SYSKIT_ENABLE_COVERAGE'] == '1' || ENV['SYSKIT_ENABLE_COVERAGE'] == '2'
    begin
        require 'simplecov'
        SimpleCov.start
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

            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def stub_syskit_task_context_model(name, &block)
                TaskContext.new_submodel(:name => name, &block)
            end

            # Create a new stub task context instance and add it to the plan
            #
            # @param [String] name the orocos_name of the new task
            # @param [Model<Syskit::TaskContext>,String,nil] task_model the task
            #   model. If a string or nil, a new task context model will be
            #   created using task_model as a name (or no name if nil). In this
            #   case, the given block is used to define the task context
            #   interface
            # @return [Syskit::TaskContext] the new task instance. It is already
            #   added to #plan
            def stub_syskit_task_context(name = "task", task_model = nil, &block)
                if !task_model || task_model.respond_to?(:to_str)
                    task_model = stub_syskit_task_context_model(task_model, &block)
                end
                plan.add_permanent(task = task_model.new(:orocos_name => name))
                task
            end

            # Create a new stub deployment model that can deploy a given task
            # context model
            #
            # @param [Model<Syskit::TaskContext>,nil] task_model if given, a
            #   task model that should be deployed by this deployment model
            # @param [String] name the name of the deployed task as well as
            #   of the deployment. If not given, and if task_model is provided,
            #   task_model.name is used as default
            # @yield the deployment model context, i.e. a context in which the
            #   same declarations than in oroGen's #deployment statement are
            #   available
            # @return [Model<Syskit::Deployment>] the deployment model. This
            #   deployment is declared as available on the 'stubs' process server,
            #   i.e. it can be started
            def stub_syskit_deployment_model(task_model = nil, name = nil, &block)
                if task_model
                    name ||= task_model.name
                end
                deployment_model = Deployment.new_submodel(:name => name) do
                    if task_model
                        task(name, task_model.orogen_model)
                    end
                    if block_given?
                        instance_eval(&block)
                    end
                end

                Syskit.conf.deployments['stubs'] << Syskit::Models::ConfiguredDeployment.new(deployment_model, Hash.new)
                Syskit.process_servers['stubs'].first.
                    register_deployment_model(deployment_model.orogen_model)
                deployment_model
            end

            # Create a new stub deployment instance
            def stub_syskit_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= stub_syskit_deployment_model(nil, name, &block)
                plan.add_permanent(task = deployment_model.new(:process_name => name, :on => 'stubs'))
                task
            end

            # Create a new deployed instance of a task context model
            #
            # @param [Model<Syskit::TaskContext>,String] task_model the task
            #   context model. If it is a string, it is the name fo a task
            #   context model that is created using a block given to the method
            # @param [String] the name of the deployed task
            #
            # @overload syskit_deploy_task_context(task_m, 'stub_task')
            # @overload syskit_deploy_task_context('Task', 'stub_task') { # output_port ... }
            def syskit_deploy_task_context(task_model, orocos_name = 'task')
                if task_model.respond_to?(:to_str)
                    task_model = stub_syskit_task_context_model(task_model, &proc)
                end
                deployment_m = stub_syskit_deployment_model(task_model, orocos_name)
                plan.add(deployment = deployment_m.new(:on => 'stubs'))
                task = deployment.task orocos_name
                plan.add_permanent(task)
                deployment.start!
                task
            end

            # Create a new deployed instance of a task context model and start
            # it
            def syskit_deploy_and_start_task_context(task_model, name = 'task')
                task = syskit_deploy_task_context(task_model, name)
                syskit_start_component(task)
                task
            end

            # Set this component instance up
            def syskit_setup_component(component)
                if component.kind_of?(Syskit::TaskContext)
                    if !component.execution_agent.running?
                        component.execution_agent.start!
                    end
                end
                component.arguments[:conf] ||= []
                component.setup
            end

            # Start this component
            #
            # If needed, it sets it up first
            def syskit_start_component(component)
                if component.kind_of?(Syskit::Composition)
                    component.each_child do |child_task|
                        if !child_task.setup?
                            syskit_setup_component(child_task)
                        end
                    end
                end
                if !component.setup?
                    syskit_setup_component(component)
                end
                if !component.running?
                    if !component.starting?
                        component.start!
                    end
                    assert_event_emission component.start_event
                end
            end

            # @deprecated
            def start_task_context(task)
                syskit_start_component(task)
            end

            # @deprecated
            def stub_roby_task_context(name = "task", task_model = nil, &block)
                stub_syskit_task_context(name, task_model, &block)
            end

            # @deprecated
            def stub_roby_deployment_model(*args, &block)
                stub_syskit_deployment_model(*args, &block)
            end

            def setup
                Roby.app.app_dir = nil
                Roby.app.search_path.clear
                @task_stubs = Array.new

                @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
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

            def deploy(*args, &block)
                syskit_run_deployer(*args, &block)
            end

            # Run Syskit's deployer (i.e. engine) on the current plan
            def syskit_run_deployer(base_task = nil, resolve_options = Hash.new, &block)
                if engine.running?
                    execute do
                        syskit_engine.redeploy
                    end
                    engine.wait_one_cycle
                else
                    syskit_engine.disable_updates
                    if base_task
                        base_task = base_task.as_plan
                        plan.add_mission(base_task)
                        if !base_task.planning_task.running?
                            base_task.planning_task.start!
                        end
                        base_task = base_task.as_service
                    end
                    syskit_engine.enable_updates
                    syskit_engine.resolve(resolve_options)
                end
                if block_given?
                    execute(&block)
                end
                if base_task
                    base_task.task
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

            def assert_raises(exception, &block)
                super(exception) do
                    begin
                        yield
                    rescue Exception => e
                        PP.pp(e, "")
                        raise
                    end
                end
            end
        end

    module SelfTest
        include Test
        include Roby::SelfTest
        include FlexMock::ArgumentTypes
        include FlexMock::MockContainer

        def setup
            ENV['ROBY_PLUGIN_PATH'] = File.expand_path(File.join(File.dirname(__FILE__), 'roby_app', 'register_plugin.rb'))
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
                @handler_ids << engine.add_propagation_handler(:type => :propagation, :late => true, &Runtime::ConnectionManagement.method(:update))
            end
        end

        def teardown
            if syskit_engine
                syskit_engine.finalize
            end
            super
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


