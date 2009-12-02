BASE_DIR = File.expand_path( '..', File.dirname(__FILE__))
$LOAD_PATH.unshift BASE_DIR
require 'test/unit'
require 'roby'
require 'roby/test/common'
require 'roby/test/testcase'
require 'roby/test/tasks/simple_task'
require 'orocos/roby/app'
require 'orocos/roby'

APP_DIR = File.join(BASE_DIR, "test")
class TC_RobyPlugin_System < Test::Unit::TestCase
    include Orocos
    include Roby::Test
    include Roby::Test::Assertions

    WORK_DIR = File.join(BASE_DIR, '..', 'test', 'working_copy')

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

        Orocos::RobyPlugin::Application.setup
        Roby.app.orogen_load_all

        @sys_model = Orocos::RobyPlugin::SystemModel.new
    end
    def teardown
        Roby.app.orocos_clear_models
        ::Orocos.instance_variable_set :@registry, Typelib::Registry.new
        ::Orocos::CORBA.instance_variable_set :@loaded_toolkits, []
        ENV['PKG_CONFIG_PATH'] = @old_pkg_config

        FileUtils.rm_rf Roby.app.log_dir

        super
    end

    def simple_composition
        sys_model.subsystem "simple" do
            add "echo::Echo"
            add "echo::Echo", :as => 'source'
            add "echo::Echo", :as => :source
        end
    end

    def test_system_instanciation
        engine = RobyPlugin::Engine.new(plan, sys_model)
        simple_composition
        engine.add "simple"

        engine.resolve_compositions
    end
end

