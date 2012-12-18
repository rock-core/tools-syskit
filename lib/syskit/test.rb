# simplecov must be loaded FIRST. Only the files required after it gets loaded
# will be profiled !!!
if ENV['SYSKIT_ENABLE_COVERAGE'] == '1'
    begin
        require 'simplecov'
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

            # The execution engine
            attr_reader :syskit_engine

            # @overload robot the robot definition
            #   @returns [Robot::RobotDefinition]
            # @overload robot { } modifies the robot definition
            #   @returns [Robot::RobotDefinition]
            def robot
                if block_given?
                    syskit_engine.robot.instance_eval(&proc)
                else
                    syskit_engine.robot
                end
            end

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
                syskit_engine.deployments['localhost'] << model
                model
            end

            def stub_deployed_task(name, task)
                task.orocos_task = Orocos::RubyTaskContext.from_orogen_model(name, task.model.orogen_model)
            end

            def setup
                @old_loglevel = Orocos.logger.level
                Roby.app.using 'syskit'
                Roby.app.filter_backtraces = false

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
                @syskit_engine = Syskit::NetworkGeneration::Engine.new(plan)
                @handler_ids = Syskit::RobyApp::Plugin.plug_engine_in_roby(engine)
		if !Syskit.conf.disables_local_process_server?
                    Syskit::RobyApp::Plugin.connect_to_local_process_server
		end
            end

            def teardown
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

            def deploy(&block)
                if engine.running?
                    execute do
                        syskit_engine.redeploy
                    end
                    engine.wait_one_cycle
                else
                    syskit_engine.resolve
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
                model.instanciate(syskit_engine, DependencyInjectionContext.new)
            end
        end

    module SelfTest
        include Test
        include Roby::SelfTest
        include FlexMock::ArgumentTypes
        include FlexMock::MockContainer

        def setup
            Roby.app.using 'syskit'
            Syskit.conf.disables_local_process_server = true

            super
            Syskit::NetworkGeneration::Engine.keep_internal_data_structures = true
            Orocos.load

            if @handler_ids
                Syskit::RobyApp::Plugin.unplug_engine_from_roby(@handler_ids, engine)
                @handler_ids = nil
            end
        end

        def teardown
            syskit_engine.finalize
            super
            flexmock_teardown
        end

        module ClassExtension
            def it(*args, &block)
                super(*args) do
                    begin
                        instance_eval(&block)
                    rescue Roby::LocalizedError => e
                        pp e
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


