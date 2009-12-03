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
class TC_RobySpec_Models < Test::Unit::TestCase
    include Orocos::RobyPlugin
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
            add 'simple_source::source', :as => 'source'
            add 'simple_sink::sink', :as => 'sink'

            add "echo::Echo"
            add "echo::Echo", :as => 'echo'
            add "echo::Echo", :as => :echo
        end
    end

    def test_simple_composition_definition
        subsys = simple_composition
        assert_equal sys_model, subsys.system
        assert(subsys < Orocos::RobyPlugin::Composition)
        assert_equal "simple", subsys.name

        assert_equal ['echo::Echo', 'echo', 'source', 'sink'].to_set, subsys.children.keys.to_set
        expected_models = %w{echo::Echo echo::Echo simple_source::source simple_sink::sink}.
            map { |model_name| sys_model.get(model_name) }
        assert_equal expected_models.to_set, subsys.children.values.to_set
    end

    def test_simple_composition_autoconnection
        subsys = sys_model.subsystem("source_sink") do
            add "simple_source::source", :as => "source"
            add "simple_sink::sink", :as => "sink"
            autoconnect
        end
        subsys.resolve_composition

        assert_equal([%w{source cycle sink cycle}],
            subsys.connections)
    end

    def test_simple_composition_ambiguity
        subsys = sys_model.subsystem("source_sink0") do
            add "simple_source::source", :as => 'source'
            add "simple_sink::sink", :as => 'sink1'
            add "simple_sink::sink", :as => 'sink2'
            autoconnect
        end
        subsys.resolve_composition

        subsys = sys_model.subsystem("source_sink1") do
            add "echo::Echo", :as => 'echo1'
            add "echo::Echo", :as => 'echo2'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.resolve_composition }

        subsys = sys_model.subsystem("source_sink2") do
            add "simple_source::source", :as => 'source1'
            add "simple_source::source", :as => 'source2'
            add "simple_sink::sink", :as => 'sink1'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.resolve_composition }
    end

    def test_simple_composition_instanciation
        subsys_model = sys_model.subsystem "simple" do
            add 'simple_source::source', :as => 'source'
            add 'simple_sink::sink', :as => 'sink'
            autoconnect

            add "echo::Echo"
            add "echo::Echo", :as => 'echo'
            add "echo::Echo", :as => :echo
        end

        subsys_model.resolve_composition
        assert_equal([["source", "cycle", "sink", "cycle"]].to_set,
            subsys_model.connections.to_set)

        subsys_task = subsys_model.instanciate(plan)
        assert_kind_of(subsys_model, subsys_task)

        children = subsys_task.each_child.to_a
        assert_equal(4, children.size)

        echo1, echo2 = plan.find_tasks(Echo::Echo).to_a
        assert(echo1)
        assert(echo2)
        source = plan.find_tasks(SimpleSource::Source).to_a.first
        assert(source)
        sink   = plan.find_tasks(SimpleSink::Sink).to_a.first
        assert(sink)

        echo_roles = [echo1, echo2].
            map do |child_task|
                info = subsys_task[child_task, TaskStructure::Dependency]
                info[:roles]
            end
        assert_equal([['echo'].to_set, [].to_set].to_set, 
                     echo_roles.to_set)

        assert_equal(['source'].to_set, subsys_task[source, TaskStructure::Dependency][:roles])
        assert_equal(['sink'].to_set, subsys_task[sink, TaskStructure::Dependency][:roles])

        assert_equal([[source, sink, ["cycle", "cycle"]]].to_set,
            Flows::DataFlow.enum_for(:each_edge).to_set)
    end

    def test_device_definition
        device_model = Orocos::RobyPlugin::Device.new_submodel("camera")
        assert_equal(device_model, Roby.app.orocos_devices['camera'])
        assert_equal("camera", device_model.name)
    end

    def test_device_driver_unknown_device_type
        model = Class.new(TaskContext)
        assert_raises(ArgumentError) do
            model.driver_for 'camera'
        end
    end

    def test_device_driver_definition
        device_model = Orocos::RobyPlugin::Device.new_submodel("camera")
        device_driver = Class.new(TaskContext) do
            driver_for 'camera'
        end
        assert(device_driver.fullfills?(device_model))
    end

    def test_device_task_selection
        device_model = Orocos::RobyPlugin::Device.new_submodel("camera")
        Echo::Echo.driver_for 'camera'

        assert_same(Echo::Echo, device_model.task_model)
        assert(Echo::Echo.arguments.include?(:device_name))
    end

    def test_device_ambiguous_task_selection
        device_model = Orocos::RobyPlugin::Device.new_submodel("camera")
        Echo::Echo.driver_for 'camera'
        SimpleSink::Sink.driver_for 'camera'

        assert_raises(Ambiguous) { device_model.task_model }
    end

    def test_device_composition
        sys_model.device_type 'camera'
        Echo::Echo.driver_for 'camera'
        subsys_model = sys_model.subsystem "simple" do
            add 'camera'
        end
        assert_equal Echo::Echo, subsys_model['camera']
    end
end

