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

module Orocos
    module RobyPlugin
        module Test
            include Orocos::RobyPlugin
            include Roby::Test
            include Roby::Test::Assertions

            module ClassExtension
                attribute(:needed_orogen_projects) { Set.new }
                def needs_orogen_projects(*names)
                    self.needed_orogen_projects |= names.to_set
                end

                def needs_no_orogen_projects
                    @needs_no_orogen_projects = true
                end
                def needs_no_orogen_projects?
                    !!@needs_no_orogen_projects
                end
            end

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
                                mock_task_context(instance)
                            end
                        else
                            mock_task_context(obj)
                        end
                    end
                else
                    result
                end
            end

            include Orocos::Test::Mocks

            def mock_roby_task_context(klass_or_instance, &block)
                klass_or_instance ||= mock_task_context_model(&block)
                if klass_or_instance.kind_of?(Class)
                    mock = flexmock(klass.new)
                elsif !klass_or_instance.respond_to?(:should_receive)
                    mock = flexmock(klass_or_instance)
                else
                    mock = klass_or_instance
                end

                mock.should_receive(:to_task).and_return(mock)
                mock.should_receive(:as_plan).and_return(mock)
                mock.should_receive(:orogen_task).and_return(mock_task_context(mock.class.orogen_spec))
                mock
            end

            Orocos::Test::Mocks::FakeTaskContext.include BGL::Vertex

            class FakeDeploymentTask < Roby::Tasks::Simple
                event :ready
                forward :start => :ready
            end

            def mock_deployment_task
                task = flexmock(FakeDeploymentTask.new)
                task.should_receive(:to_task).and_return(task)
                task.should_receive(:as_plan).and_return(task)
                plan.add(task)
                task
            end

            def mock_configured_task(task)
                if !task.execution_agent
                    task.executed_by(deployer = mock_deployment_task)
                    deployer.should_receive(:ready_to_die?).and_return(false)
                    deployer.start!
                    deployer.emit :ready
                end
                task.should_receive(:setup?).and_return(true)
            end

            def setup
                @old_loglevel = Orocos.logger.level
                Roby.app.using('orocos')

                super

                FileUtils.mkdir_p Roby.app.log_dir
                @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup

                Orocos.disable_sigchld_handler = true
                ::Orocos.initialize
                Roby.app.extend Orocos::RobyPlugin::Application

                if self.class.needed_orogen_projects.empty? && !self.class.needs_no_orogen_projects?
                    Roby.app.orogen_load_all
                else
                    self.class.needed_orogen_projects.each do |project_name|
                        Orocos.master_project.load_orogen_project project_name
                    end
                end

                engine.scheduler = Roby::Schedulers::Temporal.new(true, true, plan)

                @sys_model = Orocos::RobyPlugin::SystemModel.new
                @orocos_engine = Engine.new(plan, sys_model)
                @handler_ids = Orocos::RobyPlugin::Application.plug_engine_in_roby(engine)
            end

            def teardown
                super

                Roby.app.orocos_clear_models

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

                if !keep_logs?
                    FileUtils.rm_rf Roby.app.log_dir
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
        end
    end
end


