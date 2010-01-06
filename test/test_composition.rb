BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")
$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_Composition < Test::Unit::TestCase
    include RobyPluginCommonTest

    def simple_composition
        sys_model.subsystem "simple" do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink'

            add Echo::Echo
            add Echo::Echo, :as => 'echo'
        end
    end

    def test_simple_composition_definition
        subsys = simple_composition
        assert_equal sys_model, subsys.system
        assert(subsys < Orocos::RobyPlugin::Composition)
        assert_equal "simple", subsys.name

        assert_raises(ArgumentError) { subsys.add Echo::Echo }

        assert_equal ['Echo', 'echo', 'source', 'sink'].to_set, subsys.children.keys.to_set
        expected_models = [Echo::Echo, Echo::Echo, SimpleSource::Source, SimpleSink::Sink]
        assert_equal expected_models.map { |m| [m] }.to_set, subsys.children.values.map(&:to_a).to_set
    end

    def test_simple_composition_instanciation
        subsys_model = sys_model.subsystem "simple" do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink'
            autoconnect

            add Echo::Echo
            add Echo::Echo, :as => 'echo'
        end

        subsys_model.compute_autoconnection
        assert_equal([ [["source", "sink"], {["cycle", "cycle"] => Hash.new}] ].to_set,
            subsys_model.connections.to_set)

        orocos_engine    = Engine.new(plan, sys_model)
        subsys_task = subsys_model.instanciate(orocos_engine)
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

        assert_equal([ [source, sink, {["cycle", "cycle"] => Hash.new}] ].to_set,
            Flows::DataFlow.enum_for(:each_edge).to_set)
    end

    def test_simple_composition_autoconnection
        subsys = sys_model.subsystem("source_sink") do
            add SimpleSource::Source, :as => "source"
            add SimpleSink::Sink, :as => "sink"
            autoconnect
        end
        subsys.compute_autoconnection

        assert_equal({%w{source sink} => {%w{cycle cycle} => {}}},
            subsys.connections)
    end

    def test_simple_composition_ambiguity
        subsys = sys_model.subsystem("source_sink0") do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink1'
            add SimpleSink::Sink, :as => 'sink2'
            autoconnect
        end
        subsys.compute_autoconnection

        subsys = sys_model.subsystem("source_sink1") do
            add Echo::Echo, :as => 'echo1'
            add Echo::Echo, :as => 'echo2'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.compute_autoconnection }

        subsys = sys_model.subsystem("source_sink2") do
            add SimpleSource::Source, :as => 'source1'
            add SimpleSource::Source, :as => 'source2'
            add SimpleSink::Sink, :as => 'sink1'
            autoconnect
        end
        assert_raises(Ambiguous) { subsys.compute_autoconnection }
    end

    def test_composition_port_export
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'
            sink2  = add SimpleSink::Sink, :as => 'sink2'
        end
            
        subsys.export sink1.cycle
        assert_equal(sink1.cycle, subsys.port('cycle'))
        assert_raises(SpecError) { subsys.export(sink2.cycle) }
        
        subsys.export sink2.cycle, :as => 'cycle2'
        assert_equal(sink1.cycle, subsys.port('cycle'))
        assert_equal(sink2.cycle, subsys.port('cycle2'))
        assert_equal(sink1.cycle, subsys.cycle)
        assert_equal(sink2.cycle, subsys.cycle2)
    end

    def test_composition_connections
        subsys = sys_model.subsystem("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink   = add SimpleSink::Sink, :as => 'sink1'

            export source.cycle, :as => 'out_cycle'
            export sink.cycle, :as => 'in_cycle'
        end

        source_sink, source, sink = nil
        complete = sys_model.subsystem('all') do
            source_sink = add Compositions::SourceSink0
            source = add SimpleSource::Source
            sink   = add SimpleSink::Sink

            connect source.cycle => source_sink.in_cycle
            connect source_sink.out_cycle => sink.cycle
        end

        expected = {
            ['Source', 'source_sink0'] => { ['cycle', 'in_cycle'] => {} },
            ['source_sink0', 'Sink'] => { ['out_cycle', 'cycle'] => {} }
        }
        assert_equal(expected, complete.connections)
    end


    def test_composition_concrete_IO
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'

            export source.cycle, :as => 'out_cycle'
            export sink1.cycle, :as => 'in_cycle'
        end

        complete = sys_model.subsystem('all') do
            source_sink = add Compositions::SourceSink0
            source = add SimpleSource::Source
            sink   = add SimpleSink::Sink

            connect source.cycle => source_sink.in_cycle
            connect source_sink.out_cycle => sink.cycle
        end

        orocos_engine = Engine.new(plan, sys_model)
        orocos_engine.add(Compositions::All)
        orocos_engine.instanciate

        source_sink = plan.find_tasks(Compositions::SourceSink0).to_a.first
        source      = plan.find_tasks(SimpleSource::Source).with_parent(Compositions::All).to_a.first
        sink        = plan.find_tasks(SimpleSink::Sink).with_parent(Compositions::All).to_a.first
        deep_source = plan.find_tasks(SimpleSource::Source).with_parent(Compositions::SourceSink0, TaskStructure::Dependency).to_a.first
        deep_sink   = plan.find_tasks(SimpleSink::Sink).with_parent(Compositions::SourceSink0, TaskStructure::Dependency).to_a.first

        assert_equal [['cycle', 'cycle', deep_sink, {}]], source.each_concrete_output_connection.to_a
        assert_equal [[deep_source, 'cycle', 'cycle', {}]], sink.each_concrete_input_connection.to_a
    end

    def test_composition_port_export_instanciation
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'
        end
            
        subsys.export source.cycle, :as => 'out_cycle'
        subsys.export sink1.cycle, :as => 'in_cycle'

        orocos_engine    = Engine.new(plan, sys_model)
        orocos_engine.add(Compositions::SourceSink0)
        orocos_engine.instanciate

        tasks = plan.find_tasks(Compositions::SourceSink0).
            with_child(SimpleSink::Sink, Flows::DataFlow, ['in_cycle', 'cycle'] => Hash.new).
            with_parent(SimpleSource::Source, Flows::DataFlow, ['cycle', 'out_cycle'] => Hash.new).
            to_a
        assert_equal 1, tasks.size
    end

    def test_composition_explicit_connection
        source, sink1, sink2 = nil
        subsys = sys_model.subsystem("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'
            sink2  = add SimpleSink::Sink, :as => 'sink2'

            connect source.cycle => sink1.cycle
            connect source.cycle => sink2.cycle
        end
    end

    def test_constraints
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end
        tag   = Roby::TaskModelTag.new
        model.include tag

        subsys = sys_model.subsystem("composition") do
            add SimpleSource::Source
            constrain SimpleSource::Source,
                [tag]
        end
        assert_equal ['Source'], subsys.children.keys
        assert_equal([tag], subsys.find_child_constraint('Source'))

        orocos_engine = Engine.new(plan, sys_model)
        child = orocos_engine.add(Compositions::Composition).
            use 'Source' => SimpleSource::Source

        assert_raises(SpecError) do
            orocos_engine.instanciate
        end

        orocos_engine = Engine.new(plan, sys_model)
        child = orocos_engine.add(Compositions::Composition).
            use 'Source' => model

        orocos_engine.instanciate
    end

    def test_is_specialized_model
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end
        tag   = Roby::TaskModelTag.new do
            def self.name; "Tag1" end
        end
        tag2  = Roby::TaskModelTag.new do
            def self.name; "Tag2" end
        end
        
        assert Composition.is_specialized_model([model], [SimpleSource::Source])
        assert !Composition.is_specialized_model([SimpleSource::Source], [model])
        assert !Composition.is_specialized_model([model], [SimpleSource::Source, tag])
        assert Composition.is_specialized_model([model, tag], [SimpleSource::Source])
        assert Composition.is_specialized_model([model, tag], [SimpleSource::Source, tag])
        assert !Composition.is_specialized_model([SimpleSource::Source, tag], [model, tag])

        assert !Composition.is_specialized_model([model, tag], [SimpleSource::Source, tag2])
        model.include tag2
        assert Composition.is_specialized_model([model, tag], [SimpleSource::Source, tag2])
    end

    def test_find_specializations
        source_submodel = Class.new(SimpleSource::Source) do
            def self.name; "SourceSubmodel" end
        end
        sink_submodel = Class.new(SimpleSink::Sink) do
            def self.name; "SinkSubmodel" end
        end
        tag   = Roby::TaskModelTag.new do
            def self.name; "Tag1" end
        end
        tag2  = Roby::TaskModelTag.new do
            def self.name; "Tag2" end
        end

        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            add SimpleSink::Sink
            
            specialize SimpleSource::Source, tag
            specialize SimpleSource::Source, tag2
            specialize SimpleSink::Sink, tag
            specialize SimpleSink::Sink, tag2
        end

        assert_equal [],
            subsys.find_specializations('Source' => [SimpleSource::Source]).map(&:name)

        source_submodel_with_tag = Class.new(source_submodel) do
            def self.name; "SourceModelWithTag" end
            include tag
        end
        assert_equal ["Anoncomposition_Source_Tag1"],
            subsys.find_specializations('Source' => [source_submodel_with_tag]).map(&:name)

        source_submodel_with_tag.include tag2
        assert_equal ["Anoncomposition_Source_Tag1_Source_Tag2"],
            subsys.find_specializations('Source' => [source_submodel_with_tag]).map(&:name)

        sink_submodel_with_tag = Class.new(sink_submodel) do
            def self.name; "SinkModelWithTag" end
            include tag
        end
        assert_equal ["Anoncomposition_Source_Tag1_Source_Tag2_Sink_Tag1"],
            subsys.find_specializations('Source' => [source_submodel_with_tag], 'Sink' => [sink_submodel_with_tag]).map(&:name)

        sink_submodel_with_tag.include tag2
        assert_equal ["Anoncomposition_Source_Tag1_Source_Tag2_Sink_Tag1_Sink_Tag2"],
            subsys.find_specializations('Source' => [source_submodel_with_tag], 'Sink' => [sink_submodel_with_tag]).map(&:name)
    end

    def test_specialization
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end
        tag1  = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }

        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            
            specialize SimpleSource::Source, tag1 do
                add SimpleSink::Sink
            end
            specialize SimpleSource::Source, tag2
        end

        orocos_engine = Engine.new(plan, sys_model)
        child = orocos_engine.add(Compositions::Composition).
            use 'Source' => model
        orocos_engine.instanciate
        composition = plan.find_tasks(Compositions::Composition).
            to_a.first
        assert_same(subsys, composition.model)

        plan.clear
        model_with_tag = Class.new(model) do
            def self.name; "ModelWithTag" end
            include tag1
        end
        orocos_engine = Engine.new(plan, sys_model)
        child = orocos_engine.add(Compositions::Composition).
            use 'Source' => model_with_tag
        orocos_engine.instanciate
        composition = plan.find_tasks(Compositions::Composition).
            to_a.first
        assert(subsys != composition.model)
        assert(composition.model < subsys)

        plan.clear
        model_with_tag.include(tag2)
        orocos_engine = Engine.new(plan, sys_model)
        child = orocos_engine.add(Compositions::Composition).
            use 'Source' => model_with_tag
        orocos_engine.instanciate
        composition = plan.find_tasks(Compositions::Composition).
            to_a.first
        assert(subsys != composition.model)
        assert(composition.model < subsys)
    end

    def test_subclassing
        Roby.app.load_orogen_project 'system_test'
        tag = sys_model.data_source_type 'image' do
            output_port 'image', 'camera/Image'
        end
        submodel = Class.new(SimpleSource::Source) do
            def self.orogen_spec; superclass.orogen_spec end
            def self.name; "SubSource" end
        end
        parent = sys_model.composition("parent") do
            add SimpleSource::Source
            add SimpleSink::Sink
            autoconnect
        end
        child  = sys_model.composition("child", :child_of => parent)
        assert(child < parent)

        assert_raises(SpecError) do
            child.add Class.new(Component), :as => "Sink"
        end

        # Add another tag
        child.class_eval do
            add tag, :as => "Sink"
            add submodel, :as => 'Source'
            add SimpleSink::Sink, :as => 'Sink2'
            autoconnect
            connect self['Source'].cycle => self['Sink'].cycle, :type => :buffer, :size => 2
        end

        parent.compute_autoconnection
        child.compute_autoconnection

        assert_equal 2, parent.each_child.to_a.size
        assert_equal [SimpleSource::Source], parent.find_child('Source').to_a
        assert_equal [SimpleSink::Sink], parent.find_child('Sink').to_a
        assert_equal({["Source", "Sink"] => { ['cycle', 'cycle'] => {}}}, parent.connections)

        assert_equal 3, child.each_child.to_a.size
        assert_equal [submodel], child.find_child('Source').to_a
        assert_equal [SimpleSink::Sink, tag].to_value_set, child.find_child('Sink')
        assert_equal [SimpleSink::Sink].to_value_set, child.find_child('Sink2')
        expected_connections = {
            ["Source", "Sink"] => { ['cycle', 'cycle'] => {:type => :buffer, :pull=>false, :lock=>:lock_free, :init=>false, :size => 2} },
            ["Source", "Sink2"] => { ['cycle', 'cycle'] => {} }
        }
        assert_equal(expected_connections, child.connections)
    end
end

