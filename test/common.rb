require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'orocos/roby/app'
require 'orocos/roby'

module RobyPluginCommonTest
    include Orocos::RobyPlugin
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, 'test', 'working_copy')

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

    attr_reader :sys_model
    def setup
        super

        @update_handler = engine.each_cycle(&Orocos::RobyPlugin.method(:update))

        FileUtils.mkdir_p Roby.app.log_dir
        @old_pkg_config = ENV['PKG_CONFIG_PATH'].dup
        ENV['PKG_CONFIG_PATH'] = File.join(WORK_DIR, "prefix", 'lib', 'pkgconfig')

        ::Orocos.initialize
        Roby.app.extend Orocos::RobyPlugin::Application
        save_collection Roby.app.loaded_orogen_projects
        save_collection Roby.app.orocos_tasks
        save_collection Roby.app.orocos_deployments

        Orocos::RobyPlugin::Application.setup(Roby.app)
        if self.class.needed_orogen_projects.empty? && !self.class.needs_no_orogen_projects?
            Roby.app.orogen_load_all
        else
            self.class.needed_orogen_projects.each do |project_name|
                Roby.app.load_orogen_project project_name
            end
        end

        @sys_model = Orocos::RobyPlugin::SystemModel.new
    end
    def teardown
        Roby.app.orocos_clear_models
        ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
        ::Orocos::CORBA.instance_variable_set :@loaded_toolkits, []

        super

        FileUtils.rm_rf Roby.app.log_dir
        ENV['PKG_CONFIG_PATH'] = @old_pkg_config
    end
end


