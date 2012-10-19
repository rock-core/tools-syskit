require 'test/unit'
require 'flexmock/test_unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'orocos/roby/app'
require 'orocos/roby'
require 'roby/schedulers/temporal'
require 'utilrb/module/include'
require 'orocos/process_server'
require 'roby/tasks/simple'
require 'orocos/test'

module Orocos
    module RobyPlugin
        module Test
            include Orocos::RobyPlugin
            include Orocos::Test::Mocks

	    include Roby::Test
	    include Roby::Test::Assertions

            # The system model
            attr_reader :sys_model
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

            def mock_roby_component_model(name = nil, &block)
                # TODO: define the orogen spec / interface attribute directly on
                # Component
                mock = flexmock(Class.new(Component))
                mock.terminates
                spec = Orocos::RobyPlugin.create_orogen_interface(name)
                mock.should_receive(:orogen_spec).and_return(spec)
                if block
                    spec.instance_eval(&block)
                end
                mock.should_receive(:name).and_return(name || "")
                mock.should_receive(:short_name).and_return(name || "")
                mock
            end

            def mock_roby_task_context_model(name = nil, &block)
                mock = flexmock(Orocos::RobyPlugin::TaskContext.create(name, &block))
                mock.new_instances
                mock
            end

            def mock_roby_task_context(klass_or_instance = nil, &block)
                if !klass_or_instance
                    return mock_roby_task_context_model(&block).new
                end

                if klass_or_instance.kind_of?(Class)
                    mock = flexmock(klass.new)
                elsif !klass_or_instance.respond_to?(:should_receive)
                    mock = flexmock(klass_or_instance)
                else
                    mock = klass_or_instance
                end
                mock
            end

            def mock_roby_deployment_model(task_model)
                if !task_model.name
                    raise ArgumentError, "cannot create a deployment model for a task that has no name"
                end

                # TODO: move the deployment specification to Spec in oroGen
                # TODO: remove requirement for things to have name here. This
                # will require to cleanup the oroGen loading / registration
                # mechanisms so that objects are unique
                spec = Orocos::Generation::Deployment.new(Orocos.master_project, nil)
                spec.task('task', task_model.interface)
                model = Orocos::RobyPlugin::Deployment.create(nil, spec)
                orocos_engine.deployments['localhost'] << model
                Roby.app.orocos_tasks[task_model.orogen_spec.name] = task_model
                model
            end

            def mock_roby_composition_model(name = '', &block)
                model = Composition.new_submodel name, sys_model
                if block
                    model.instance_eval(&block)
                end
                model = flexmock(model)
                model.new_instances
                model
            end

            Orocos::Test::Mocks::FakeTaskContext.include BGL::Vertex

            class FakeDeploymentTask < Roby::Tasks::Simple
                event :ready
                forward :start => :ready
            end

            def mock_deployment_task
                task = flexmock(FakeDeploymentTask.new)
                plan.add(task)
                task
            end

            def mock_configured_task(task)
                task.should_receive(:orogen_task).and_return(mock_task_context(task.model.orogen_spec))
                if !task.execution_agent
                    task.executed_by(deployer = mock_deployment_task)
                    deployer.should_receive(:ready_to_die?).and_return(false)
                    deployer.start!
                    deployer.emit :ready
                end
                task.should_receive(:setup?).and_return(true).by_default
                task.should_receive(:execute).and_yield.by_default
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

                engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

                # TODO: remove all references to global singletons
                @sys_model = Roby.app.orocos_system_model
                save_collection Roby.app.orocos_engine.instances
                @orocos_engine = Roby.app.orocos_engine
                Roby.app.orocos_engine.instance_variable_set :@plan, plan
                @handler_ids = Orocos::RobyPlugin::Application.plug_engine_in_roby(engine)
		if !Roby.app.orocos_disables_local_process_server?
                    Orocos::RobyPlugin::Application.connect_to_local_process_server
		end
            end

            def teardown
                orocos_engine.clear
                Roby.app.orocos_clear_models

                super

                if plan
                    deployments = plan.find_tasks(Deployment).running.to_a
                    deployments.each do |task|
                        if task.orogen_deployment.alive?
                            task.orogen_deployment.kill
                        end
                    end
                end

            ensure
                if @handler_ids
                    Orocos::RobyPlugin::Application.unplug_engine_from_roby(@handler_ids, engine)
                end

                ENV['PKG_CONFIG_PATH'] = @old_pkg_config
                Orocos.logger.level = @old_loglevel if @old_loglevel
            end

            def method_missing(m, *args, &block)
                if orocos_engine.respond_to?(m)
                    orocos_engine.send(m, *args, &block)
                elsif sys_model.respond_to?(m)
                    sys_model.send(m, *args, &block)
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
    end
end


