BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")
$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_Composition < Test::Unit::TestCase
    include RobyPluginCommonTest

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
        subsys.compute_autoconnection

        assert_equal({%w{source sink} => {%w{cycle cycle} => {}}},
            subsys.connections)
    end

    def test_simple_composition_ambiguity
        subsys = sys_model.subsystem("source_sink0") do
            add "simple_source::source", :as => 'source'
            add "simple_sink::sink", :as => 'sink1'
            add "simple_sink::sink", :as => 'sink2'
            autoconnect
        end
        subsys.compute_autoconnection

        subsys = sys_model.subsystem("source_sink1") do
            add "echo::Echo", :as => 'echo1'
            add "echo::Echo", :as => 'echo2'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.compute_autoconnection }

        subsys = sys_model.subsystem("source_sink2") do
            add "simple_source::source", :as => 'source1'
            add "simple_source::source", :as => 'source2'
            add "simple_sink::sink", :as => 'sink1'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.compute_autoconnection }
    end

    def test_composition_port_export
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add "simple_source::source", :as => 'source'
            sink1  = add "simple_sink::sink", :as => 'sink1'
            sink2  = add "simple_sink::sink", :as => 'sink2'
        end
            
        subsys.export sink1.cycle
        assert_same(sink1.cycle, subsys.port('cycle'))
        assert_raises(SpecError) { subsys.export(sink2.cycle) }
        
        subsys.export sink2.cycle, :as => 'cycle2'
        assert_same(sink1.cycle, subsys.port('cycle'))
        assert_same(sink2.cycle, subsys.port('cycle2'))
        assert_same(sink1.cycle, subsys.cycle)
        assert_same(sink2.cycle, subsys.cycle2)
    end

    def test_composition_explicit_connection
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add "simple_source::source", :as => 'source'
            sink1  = add "simple_sink::sink", :as => 'sink1'
            sink2  = add "simple_sink::sink", :as => 'sink2'

            connect source.cycle => sink1.cycle
            connect source.cycle => sink2.cycle
        end
    end
end

