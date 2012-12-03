require 'test/unit'
require 'flexmock/test_unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'syskit/app'
require 'syskit'
require 'roby/schedulers/temporal'
require 'utilrb/module/include'
require 'orocos/process_server'
require 'roby/tasks/simple'
require 'orocos/test'

begin
    require 'simplecov'
    if ENV['SYSKIT_ENABLE_COVERAGE'] == '1'
        SimpleCov.command_name 'syskit'
        root = File.expand_path(File.join("..", ".."), File.dirname(__FILE__))
        SimpleCov.root(root)
        SimpleCov.add_filter "/test/"
        SimpleCov.start
    end
rescue LoadError
    Syskit.warn "coverage is disabled because the 'simplecov' gem cannot be loaded"
rescue Exception => e
    Syskit.warn "coverage is disabled: #{e.message}"
end

begin
require 'pry'
rescue Exception
    Syskit.warn "debugging is disabled because the 'pry' gem cannot be loaded"
end

module Syskit
        module Test
            include Syskit
            include Orocos::Test::Mocks

	    include Roby::Test
	    include Roby::Test::Assertions

            # The execution engine
            attr_reader :orocos_engine

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

            def stub_roby_task_context(name = "task", &block)
                task_model = TaskContext.new_submodel(&block)
                task = task_model.new
                task.stub! name
                @task_stubs << task.orocos_task
                task
            end

            def stub_roby_deployment_model(task_model, name = task_model.name)
                orogen_model = Orocos::Spec::Deployment.new(Orocos.master_project, name)
                orogen_model.task name, task_model.orogen_model
                model = Deployment.new_submodel(:orogen_model => orogen_model)
                orocos_engine.deployments['localhost'] << model
                model
            end

            def stub_deployed_task(name, task)
                task.orocos_task = Orocos::RubyTaskContext.from_orogen_model(name, task.model.orogen_model)
            end

            def setup
                @old_loglevel = Orocos.logger.level
		Roby.app.using 'orocos'

                super

                FileUtils.mkdir_p Roby.app.log_dir
                @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup

                if !Orocos.initialized?
                    Orocos.disable_sigchld_handler = true
                    ::Orocos.initialize
                end

                @task_stubs = Array.new

                engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

                # TODO: remove all references to global singletons
                save_collection Roby.app.orocos_engine.instances
                @orocos_engine = Roby.app.orocos_engine
                Roby.app.orocos_engine.instance_variable_set :@plan, plan
                @handler_ids = Syskit::Application.plug_engine_in_roby(engine)
		if !Roby.app.orocos_disables_local_process_server?
                    Syskit::Application.connect_to_local_process_server
		end
            end

            def teardown
                if orocos_engine
                    orocos_engine.clear
                end
                Roby.app.orocos_clear_models

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
                    Syskit::Application.unplug_engine_from_roby(@handler_ids, engine)
                end

                ENV['PKG_CONFIG_PATH'] = @old_pkg_config
                Orocos.logger.level = @old_loglevel if @old_loglevel
            end

            def method_missing(m, *args, &block)
                if orocos_engine.respond_to?(m)
                    orocos_engine.send(m, *args, &block)
                else super
                end
            end

            attr_predicate :keep_logs?, true

            def deploy(&block)
                if engine.running?
                    execute do
                        orocos_engine.redeploy
                    end
                    engine.wait_one_cycle
                else
                    orocos_engine.resolve
                end
                if block_given?
                    execute(&block)
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
                        puts "task=#{to} planner=#{planner}"
                        if planner.kind_of?(SingleRequirementTask)
                            requirements << planner.arguments[:name]
                        end
                    end
                end

                # Do a copy of the currently loaded instances in the engine.
                current_instances = orocos_engine.instances.dup
                requirements.each do |req_name|
                    orocos_engine.clear
                    orocos_engine.instances.concat(current_instances)
                    orocos_engine.add(req_name)
                    
                    this = Time.now
                    gc = GC.count
                    GC::Profiler.clear
                    GC::Profiler.enable
                    orocos_engine.resolve
                    puts "resolved #{req_name} in #{Time.now - this} seconds (ran GC #{GC.count - gc} times)"
                    puts GC::Profiler.result
                    GC::Profiler.disable
                end

            ensure
                if current_instances
                    orocos_engine.clear
                    orocos_engine.instances.concat(instances)
                end
            end

            def instanciate_component(model)
                orocos_engine.add_instance(model)
            end
        end

    module SelfTest
        include Test
        include Roby::SelfTest

        def setup
            Roby.app.using 'orocos'
            Roby.app.orocos_disables_local_process_server = true

            super
            Orocos.load
        end

        def data_service_type(name, &block)
            DataService.new_submodel(:name => name, &block)
        end
    end
end


