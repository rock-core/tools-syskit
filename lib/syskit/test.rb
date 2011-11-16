require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'orocos/roby/app'
require 'orocos/roby'
require 'roby/schedulers/temporal'
require 'utilrb/module/include'
require 'orocos/process_server'

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

            def setup
                @old_loglevel = Orocos.logger.level
                Roby.app.using('orocos')

                super

                FileUtils.mkdir_p Roby.app.log_dir
                @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup

                Orocos.disable_sigchld_handler = true
                ::Orocos.initialize
                Roby.app.extend Orocos::RobyPlugin::Application
                save_collection Roby.app.loaded_orogen_projects
                save_collection Roby.app.orocos_tasks
                save_collection Roby.app.orocos_deployments
                save_collection Orocos::RobyPlugin.process_servers

                project = Orocos::Generation::Component.new
                project.name 'roby'
                Roby.app.instance_variable_set :@main_orogen_project, project

                if self.class.needed_orogen_projects.empty? && !self.class.needs_no_orogen_projects?
                    Roby.app.orogen_load_all
                else
                    self.class.needed_orogen_projects.each do |project_name|
                        Roby.app.load_orogen_project project_name
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
                ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
                ::Orocos::CORBA.instance_variable_set :@loaded_typekits, []

                deployments = plan.find_tasks(Deployment).running.to_a

                deployments.each do |task|
                    if task.orogen_deployment.alive?
                        task.orogen_deployment.kill
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


