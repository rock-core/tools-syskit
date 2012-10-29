BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")
$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'
require 'flexmock'

class TC_RobySpec_Composition < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def define_stereocamera
        Roby.app.load_orogen_project "system_test"

        sys_model.data_service_type 'StereoProvider' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        sys_model.device_type 'StereoCam' do
            provides Srv::StereoProvider
            output_port 'image1', 'camera::Image'
            output_port 'image2', 'camera::Image'
        end
        sys_model.data_service_type 'Image' do
            output_port 'image', 'camera::Image'
        end
        sys_model.device_type 'Camera' do
            provides Srv::Image
        end

        task_model = SystemTest::StereoCamera
        task_model.driver_for Dev::StereoCam, :as => 'stereo', 'image1' => 'leftImage', 'image2' => 'rightImage'
        task_model.provides Srv::Image, :as => 'left',  :slave_of => 'stereo'
        task_model.provides Srv::Image, :as => 'right', :slave_of => 'stereo'

        task_model = SystemTest::StereoProcessing
        task_model.provides Srv::StereoProvider, :as => 'stereo'

        SystemTest::CameraDriver.provides Dev::Camera, :as => 'camera'

        task_model
    end

    def simple_composition
        define_stereocamera
        sys_model.composition "StereoProcessing" do
            add Srv::Image, :as => 'image1'
            add Srv::Image, :as => 'image2'
            main = add_main_task SystemTest::StereoProcessing, :as => 'processing'

            export main.disparity
            export main.cloud
            provides Srv::StereoProvider
        end
    end

    def test_add
        subsys = simple_composition

        assert_equal sys_model, subsys.system_model
        assert(subsys < Orocos::RobyPlugin::Composition)
        assert_same Cmp::StereoProcessing, Orocos::RobyPlugin::Compositions::StereoProcessing
        assert_equal "Orocos::RobyPlugin::Compositions::StereoProcessing", subsys.name

        assert_equal ['image1', 'image2', 'processing'].to_set,
            subsys.children.keys.to_set

        expected_models = [Srv::Image, Srv::Image, SystemTest::StereoProcessing]
        assert_equal expected_models.map { |m| [m] }.to_set,
            subsys.children.values.map(&:models).map(&:to_a).to_set
    end

    def test_export
        Roby.app.load_orogen_project "simple_source"
        Roby.app.load_orogen_project "simple_sink"
        source, sink1, sink2 = nil
        subsys = sys_model.composition("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'
            sink2  = add SimpleSink::Sink, :as => 'sink2'
        end
            
        subsys.export sink1.cycle
        assert_equal(sink1.cycle, subsys.find_input_port('cycle'))
        assert_raises(ArgumentError) { subsys.export(sink2.cycle) }
        
        subsys.export sink2.cycle, :as => 'cycle2'
        assert_equal(sink1.cycle, subsys.find_input_port('cycle'))
        assert_equal(sink2, subsys.find_input_port('cycle2').child)
        assert_equal(sink2.cycle.port, subsys.find_input_port('cycle2').port)
        assert_equal(sink1.cycle, subsys.cycle)
        assert_equal(subsys.find_input_port('cycle2'), subsys.cycle2)
    end

    def test_compute_autoconnection
        Roby.app.load_orogen_project "echo"
        subsys_model = sys_model.composition "simple" do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink'
            autoconnect

            add Echo::Echo
            add Echo::Echo, :as => 'echo'
        end

        subsys_model.compute_autoconnection
        assert_equal([ [["source", "sink"], {["cycle", "cycle"] => Hash.new}] ].to_set,
            subsys_model.connections.to_set)
    end

    def test_compute_autoconnection_ambiguities
        Roby.app.load_orogen_project 'echo'
        subsys = sys_model.composition("source_sink0") do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink1'
            add SimpleSink::Sink, :as => 'sink2'
            autoconnect
        end
        subsys.compute_autoconnection

        subsys = sys_model.composition("source_sink1") do
            add Echo::Echo, :as => 'echo1'
            add Echo::Echo, :as => 'echo2'
            autoconnect
        end
        assert_raises(AmbiguousAutoConnection) { subsys.compute_autoconnection }

        subsys = sys_model.composition("source_sink2") do
            add SimpleSource::Source, :as => 'source1'
            add SimpleSource::Source, :as => 'source2'
            add SimpleSink::Sink, :as => 'sink1'
            autoconnect
        end
        assert_raises(AmbiguousAutoConnection) { subsys.compute_autoconnection }
    end

    def test_connect_overrides_autoconnect
        Roby.app.load_orogen_project "echo"
        explicit_policy = { :type => :buffer, :size => 10 }
        subsys_model = sys_model.composition "simple" do
            source = add SimpleSource::Source, :as => 'source'
            sink   = add SimpleSink::Sink, :as => 'sink'
            autoconnect
            connect explicit_policy.merge(source.cycle => sink.cycle)

            add Echo::Echo
            add Echo::Echo, :as => 'echo'
        end

        expected_policy = Kernel.validate_options explicit_policy,
            Orocos::Port::CONNECTION_POLICY_OPTIONS

        subsys_model.compute_autoconnection
        assert_equal([ [["source", "sink"], {["cycle", "cycle"] => expected_policy}] ].to_set,
            subsys_model.connections.to_set)
    end

    def test_connect
        Roby.app.load_orogen_project "echo"
        subsys_model = sys_model.composition "simple" do
            source = add SimpleSource::Source, :as => 'source'
            sink   = add SimpleSink::Sink, :as => 'sink'
            connect source.cycle => sink.cycle, :type => :buffer

            e0 = add Echo::Echo
            e1 = add Echo::Echo, :as => 'echo'
            connect e0.output => e1.input, :type => :data
        end

        expected_data_policy = Kernel.validate_options({ :type => :data },
            Orocos::Port::CONNECTION_POLICY_OPTIONS)

        expected_buffer_policy = Kernel.validate_options({ :type => :buffer },
            Orocos::Port::CONNECTION_POLICY_OPTIONS)

        expected_connections = [
            [["source", "sink"], {["cycle", "cycle"] => expected_buffer_policy}],
            [["Echo", "echo"], {["output", "input"] => expected_data_policy}]
        ]

        subsys_model.compute_autoconnection
        assert_equal(expected_connections.to_set,
            subsys_model.connections.to_set)
    end

    def test_connect_exported_ports
        subsys = sys_model.composition("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink   = add SimpleSink::Sink, :as => 'sink1'

            export source.cycle, :as => 'out_cycle'
            export sink.cycle, :as => 'in_cycle'
        end

        source_sink, source, sink = nil
        complete = sys_model.composition('all') do
            source_sink = add Compositions::SourceSink0
            source = add SimpleSource::Source
            sink   = add SimpleSink::Sink

            connect source.cycle => source_sink.in_cycle
            connect source_sink.out_cycle => sink.cycle
        end

        expected = {
            ['Source', 'SourceSink0'] => { ['cycle', 'in_cycle'] => {} },
            ['SourceSink0', 'Sink'] => { ['out_cycle', 'cycle'] => {} }
        }
        assert_equal(expected, complete.connections)
    end


    def test_instanciate_connections
        Roby.app.load_orogen_project "echo"
        subsys_model = sys_model.composition "simple" do
            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink'
            autoconnect

            e0 = add Echo::Echo
            e1 = add Echo::Echo, :as => 'echo'
            connect e0.output => e1.input, :type => :data
        end

        expected_data_policy = Kernel.validate_options({ :type => :data },
            Orocos::Port::CONNECTION_POLICY_OPTIONS)

        task = subsys_model.instanciate(orocos_engine)
        echo0  = task.child_from_role('Echo')
        echo1  = task.child_from_role('echo')
        source = task.child_from_role('source')
        sink   = task.child_from_role('sink')

        assert_equal({ ['output', 'input'] => expected_data_policy },
                     echo0[echo1, Flows::DataFlow])
        assert_equal({ ['cycle', 'cycle'] => Hash.new },
                     source[sink, Flows::DataFlow])
    end

    def test_instanciate_indirect_composition_selection
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end
        tag1  = Roby::TaskModelTag.new do
            def self.name; "Tag1" end
        end
        tag2  = Roby::TaskModelTag.new do
            def self.name; "Tag2" end
        end
        spec1, spec2 = nil
        subsys = sys_model.composition("source_sink0") do
            include tag1

            add SimpleSource::Source, :as => 'source'
            add SimpleSink::Sink, :as => 'sink1'
        end

        spec1 = sys_model.composition("source_sink1", :child_of => subsys) do
            add tag1, :as => 'source'
        end
        spec2 = sys_model.composition("source_sink2", :child_of => spec1) do
            add tag2, :as => 'source'
        end

        test = sys_model.composition('test') do
            add tag1, :as => 'child'
        end

        orocos_engine    = Engine.new(plan, sys_model)
        orocos_engine.prepare

        selection = test.find_selected_compositions(
            "child", Hash.new)
        assert_equal [], selection

        selection = test.find_selected_compositions(
            "child", "child.not_a_child" => SimpleSource::Source)
        assert_equal [], selection

        selection = test.find_selected_compositions(
            "child", "child.source" => SimpleSource::Source)
        assert_equal [subsys], selection

        model.include tag1
        selection = test.find_selected_compositions(
            "child", "child.source" => model)
        assert_equal [spec1].to_set, selection.to_set

        model.include tag2
        selection = test.find_selected_compositions(
            "child", "child.source" => model)
        assert_equal [spec2].to_set, selection.to_set
    end

    def test_instanciate_exported_ports
        source, sink1, sink2 = nil
        subsys = sys_model.composition("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'
        end
            
        subsys.export source.cycle, :as => 'out_cycle'
        subsys.export sink1.cycle, :as => 'in_cycle'

        task   = subsys.instanciate(orocos_engine)
        source = task.child_from_role('source')
        sink   = task.child_from_role('sink1')

        assert_equal({ ['cycle', 'out_cycle'] => Hash.new },
            source[task, Flows::DataFlow])
        assert_equal({ ['in_cycle', 'cycle'] => Hash.new },
            task[sink, Flows::DataFlow])
    end

    def test_compare_model_sets
        tag = Roby::TaskModelTag.new
        subtag = Roby::TaskModelTag.new do
            include tag
        end
        submodel = Class.new(SimpleSource::Source)

        assert_equal 0, Composition.compare_model_sets(
            [SimpleSource::Source], [SimpleSource::Source])
        assert_equal nil, Composition.compare_model_sets(
            [SimpleSource::Source, tag], [SimpleSource::Source])
        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source], [SimpleSource::Source, tag])
        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source, tag], [SimpleSource::Source, subtag])

        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source], [submodel])
        assert_equal nil, Composition.compare_model_sets(
            [submodel], [SimpleSource::Source])
        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source], [submodel, subtag])
        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source, tag], [submodel, subtag])
        assert_equal nil, Composition.compare_model_sets(
            [submodel], [subtag])
        assert_equal nil, Composition.compare_model_sets(
            [submodel], [SimpleSource::Source, subtag])

        tag2  = Roby::TaskModelTag.new
        submodel.include subtag
        assert_equal nil, Composition.compare_model_sets(
            [SimpleSource::Source, tag, subtag, tag2], [submodel])
        submodel.include tag2
        assert_equal 1, Composition.compare_model_sets(
            [SimpleSource::Source, tag, subtag, tag2], [submodel])
        assert_equal 0, Composition.compare_model_sets(
            [SimpleSource::Source, tag, subtag, tag2], [SimpleSource::Source, subtag, tag2])
        assert_equal nil, Composition.compare_model_sets(
            [submodel], [SimpleSource::Source, tag, subtag, tag2])
    end

    def test_find_most_specialized_compositions
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

        c1, c2, c3, c4 = nil
        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            add SimpleSink::Sink
            
            c1 = specialize SimpleSource::Source, tag
            c2 = specialize SimpleSource::Source, tag2
            c3 = specialize SimpleSink::Sink, tag
            c4 = specialize SimpleSink::Sink, tag2
        end

        c12  = c1.specializations[0].composition
        c13  = c1.specializations[1].composition
        c14  = c1.specializations[2].composition

        c23  = c2.specializations[0].composition
        c24  = c2.specializations[1].composition

        c123 = c12.specializations[0].composition
        c124 = c12.specializations[1].composition

        c134 = c13.specializations[0].composition
        c234 = c23.specializations[0].composition

        c1234 = c123.specializations[0].composition

        assert_equal [subsys, c1, c2, c12, c123, c1234],
            subsys.find_most_specialized_compositions(
                   [subsys, c1, c2, c12, c123, c1234], Array.new)
        assert_equal [c12],
            subsys.find_most_specialized_compositions(
                   [subsys, c1, c2, c3, c4, c12], ['Source'])
        assert_equal [c12, c3, c4].to_set,
            subsys.find_most_specialized_compositions(
                   [subsys, c1, c2, c3, c4, c12], ['Source', 'Sink']).to_set
        assert_equal [c12].to_set,
            subsys.find_most_specialized_compositions(
                   [subsys, c1, c2, c3, c4, c12, c123, c1234], ['Source']).to_set
    end

    def test_find_specializations
        source_submodel = Class.new(SimpleSource::Source) { def self.name; "SourceSubmodel" end }
        sink_submodel   = Class.new(SimpleSink::Sink) { def self.name; "SinkSubmodel" end }
        tag   = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }

        source1, source2, sink1, sink2 = nil
        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            add SimpleSink::Sink
            
            source1 = specialize SimpleSource::Source, tag
            source2 = specialize SimpleSource::Source, tag2
            sink1 = specialize SimpleSink::Sink, tag
            sink2 = specialize SimpleSink::Sink, tag2
        end

        source12       = source1.specializations[0].composition
        source1_sink1  = source1.specializations[1].composition
        source1_sink2  = source1.specializations[2].composition
        source2_sink1  = source2.specializations[0].composition
        source2_sink2  = source2.specializations[1].composition
        source12_sink1 = source12.specializations[0].composition
        source12_sink2 = source12.specializations[1].composition
        source1_sink12 = source1_sink1.specializations[0].composition
        source2_sink12 = source2_sink1.specializations[0].composition
        source12_sink12 = source12_sink1.specializations[0].composition

        assert_equal [], subsys.find_specializations(
                'Source' => [SimpleSource::Source]).map(&:name)

        source_submodel_with_tag = Class.new(source_submodel) do
            def self.name; "SourceModelWithTag" end
            include tag
        end
        assert_equal [source1], subsys.find_specializations(
                'Source' => [source_submodel_with_tag])

        source_submodel_with_tag.include tag2
        assert_equal [source12],
            subsys.find_specializations(
                'Source' => [source_submodel_with_tag])

        sink_submodel_with_tag = Class.new(sink_submodel) do
            def self.name; "SinkModelWithTag" end
            include tag
        end
        assert_equal [source12_sink1], subsys.find_specializations(
                'Sink' => [sink_submodel_with_tag],
                'Source' => [source_submodel_with_tag])
        # Verify that we get the same result, regardless of the selection order
        assert_equal [source12_sink1], subsys.find_specializations(
                'Source' => [source_submodel_with_tag],
                'Sink' => [sink_submodel_with_tag])

        sink_submodel_with_tag.include tag2
        assert_equal [source12_sink12], subsys.find_specializations(
                'Sink' => [sink_submodel_with_tag],
                'Source' => [source_submodel_with_tag])
        # Verify that we get the same result, regardless of the selection order
        assert_equal [source12_sink12], subsys.find_specializations(
                'Source' => [source_submodel_with_tag],
                'Sink' => [sink_submodel_with_tag])
    end

    def test_model_specialize
        tag1  = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end

        specialized_source_model = nil
        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            
            specialize SimpleSource::Source, tag1 do
                add SimpleSink::Sink
            end
            specialize SimpleSource::Source, tag2
        end

        spec_tag1  = subsys.specializations[0]
        spec_tag2  = subsys.specializations[1]
        spec_tag12 = spec_tag1.composition.specializations[0]

        assert(spec_tag1.composition.specialized_on?('Source', tag1))
        assert(!spec_tag1.composition.specialized_on?('Source', tag2))
        assert(spec_tag2.composition.specialized_on?('Source', tag2))
        assert(!spec_tag2.composition.specialized_on?('Source', tag1))
        assert(spec_tag12.composition.specialized_on?('Source', tag1))
        assert(spec_tag12.composition.specialized_on?('Source', tag2))

        assert_equal [SimpleSource::Source].to_value_set,
             subsys.children['Source'].models
        assert_equal([SimpleSource::Source, tag1].to_value_set,
             spec_tag1.composition.children['Source'].models)
        assert_equal([SimpleSink::Sink].to_value_set,
             spec_tag1.composition.children['Sink'].models)
        assert_equal([SimpleSource::Source, tag2].to_value_set,
             spec_tag2.composition.children['Source'].models)
        assert_equal([SimpleSource::Source, tag1, tag2].to_value_set,
             spec_tag12.composition.children['Source'].models)
    end

    def test_model_find_specialization_exact
        tag  = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        model0 = Class.new(SimpleSource::Source) do
            def self.name; "Model0" end
            include tag
        end
        submodel0 = Class.new(model0)
        model1 = Class.new(SimpleSource::Source) do
            def self.name; "Model1" end
            include tag
        end

        spec0, spec0_submodel = nil
        subsys = sys_model.composition("composition") do
            add tag, :as => 'child'
            
            spec0 = specialize 'child', model0 do
                spec0_submodel = specialize "child", submodel0
            end
        end

        assert_equal [], subsys.find_specializations(
                'child' => [model1])
        assert_equal [spec0], subsys.find_specializations(
                'child' => [model0])
        assert_equal [spec0_submodel], subsys.find_specializations(
                'child' => [submodel0])
    end

    def test_specialize_with_incompatible_models
        tag  = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        model0 = Class.new(SimpleSource::Source) do
            def self.name; "Model0" end
            include tag
        end
        model1 = Class.new(SimpleSource::Source) do
            def self.name; "Model1" end
            include tag
        end

        spec0, spec1 = nil
        subsys = sys_model.composition("composition") do
            add tag, :as => 'child'
            
            spec0 = specialize 'child', model0
            spec1 = specialize 'child', model1
        end

        # There should be no cross-specializations since model0 and model1 are
        # incompatible
        assert spec0.specializations.empty?
        assert spec1.specializations.empty?
    end

    def test_instanciate_specializations
        tag1  = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
        end

        specialized_source_model = nil
        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            
            specialize SimpleSource::Source, tag1 do
                add SimpleSink::Sink
            end
            specialize SimpleSource::Source, tag2
        end

        spec_tag1  = subsys.specializations[0]
        spec_tag2  = subsys.specializations[1]
        spec_tag12 = spec_tag1.composition.specializations[0]

        task = subsys.instanciate(orocos_engine,
                    :selection => { 'Source' => model })
        assert_same(subsys, task.model)

        model_with_tag = Class.new(model) do
            def self.name; "ModelWithTag" end
            include tag1
        end
        task = subsys.instanciate(orocos_engine,
                    :selection => { 'Source' => model_with_tag })
        assert_same(spec_tag1.composition, task.model)

        model_with_tag.include(tag2)
        task = subsys.instanciate(orocos_engine,
                    :selection => { 'Source' => model_with_tag })
        assert_same(spec_tag12.composition, task.model)
    end

    def test_instanciate_specialization_ambiguity
        tag   = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
            include tag
            include tag2
        end

        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            specialize SimpleSource::Source, tag, :not => tag2
            specialize SimpleSource::Source, tag2, :not => tag
        end

        assert_raises(AmbiguousSpecialization) do
            subsys.instanciate(orocos_engine,
                :selection => { 'Source' => model })
        end
    end

    def test_instanciate_default_specialization
        tag   = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
            include tag
            include tag2
        end

        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            specialize SimpleSource::Source, tag, :not => tag2
            specialize SimpleSource::Source, tag2, :not => tag

            default_specialization 'Source', tag
        end

        spec_tag1  = subsys.specializations[0]
        spec_tag2  = subsys.specializations[1]

        task = subsys.instanciate(orocos_engine,
            :selection => { 'Source' => model })
        assert_same(spec_tag1.composition, task.model)
    end

    def test_instanciate_faceted_specialization
        tag   = Roby::TaskModelTag.new { def self.name; "Tag1" end }
        tag2  = Roby::TaskModelTag.new { def self.name; "Tag2" end }
        model = Class.new(SimpleSource::Source) do
            def self.name; "Model" end
            include tag
            include tag2
        end

        subsys = sys_model.composition("composition") do
            add SimpleSource::Source
            specialize SimpleSource::Source, tag, :not => tag2
            specialize SimpleSource::Source, tag2, :not => tag

            default_specialization SimpleSource::Source, tag
        end

        spec_tag1  = subsys.specializations[0]
        spec_tag2  = subsys.specializations[1]

        task = subsys.instanciate(orocos_engine,
            :selection => { 'Source' => model.as(tag) })
        assert_same(spec_tag1.composition, task.model)

        task = subsys.instanciate(orocos_engine,
            :selection => { 'Source' => model.as(tag2) })
        assert_same(spec_tag2.composition, task.model)
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

        bad_model = Class.new(Component) do
            def self.name; "BadModel" end
        end
        assert_raises(ArgumentError) do
            child.add bad_model, :as => "Sink"
        end

        # Add another tag
        child.add tag, :as => "Sink"
        child.add submodel, :as => 'Source'
        child.add SimpleSink::Sink, :as => 'Sink2'
        child.autoconnect
        child.connect child['Source'].cycle => child['Sink'].cycle,
            :type => :buffer, :size => 2

        parent.compute_autoconnection
        child.compute_autoconnection

        assert_equal 2, parent.each_child.to_a.size
        assert_equal [SimpleSource::Source], parent.find_child('Source').models.to_a, parent.children.keys.join(", ")
        assert_equal [SimpleSink::Sink], parent.find_child('Sink').models.to_a
        assert_equal({["Source", "Sink"] => { ['cycle', 'cycle'] => {}}}, parent.connections)

        assert_equal 3, child.each_child.to_a.size
        assert_equal [submodel], child.find_child('Source').models.to_a
        assert_equal [SimpleSink::Sink, tag].to_value_set, child.find_child('Sink').models.to_value_set
        assert_equal [SimpleSink::Sink].to_value_set, child.find_child('Sink2').models.to_value_set
        expected_connections = {
            ["Source", "Sink"] => { ['cycle', 'cycle'] => {:type => :buffer, :pull=>false, :lock=>:lock_free, :init=>false, :size => 2} },
            ["Source", "Sink2"] => { ['cycle', 'cycle'] => {} }
        }
        assert_equal(expected_connections, child.connections)
    end

    def test_composition_concrete_IO
        Roby.app.load_orogen_project 'simple_source'
        Roby.app.load_orogen_project 'simple_sink'

        source, sink1, sink2 = nil
        subsys = sys_model.composition("source_sink0") do
            source = add SimpleSource::Source, :as => 'source'
            sink1  = add SimpleSink::Sink, :as => 'sink1'

            export source.cycle, :as => 'out_cycle'
            export sink1.cycle, :as => 'in_cycle'
        end
        assert subsys.output_port('out_cycle')
        assert subsys.input_port('in_cycle')

        complete = sys_model.composition('all') do
            source_sink = add Compositions::SourceSink0
            source = add SimpleSource::Source
            sink   = add SimpleSink::Sink

            connect source.cycle => source_sink.in_cycle
            connect source_sink.out_cycle => sink.cycle

            export source_sink.out_cycle, :as => 'out'
            export source_sink.in_cycle, :as => 'in'
        end

        orocos_engine = Engine.new(plan, sys_model)
        composition = orocos_engine.add(Compositions::All)
        orocos_engine.instanciate

        composition = composition.task
        source_sink = plan.find_tasks(Compositions::SourceSink0).to_a.first
        source      = plan.find_tasks(SimpleSource::Source).with_parent(Compositions::All).to_a.first
        sink        = plan.find_tasks(SimpleSink::Sink).with_parent(Compositions::All).to_a.first
        deep_source = plan.find_tasks(SimpleSource::Source).with_parent(Compositions::SourceSink0, TaskStructure::Dependency).to_a.first
        deep_sink   = plan.find_tasks(SimpleSink::Sink).with_parent(Compositions::SourceSink0, TaskStructure::Dependency).to_a.first

        assert(source_sink)
        assert(source)
        assert(sink)
        assert(deep_source)
        assert(deep_sink)

        assert_equal [['cycle', 'cycle', deep_sink, {}]], source.each_concrete_output_connection.to_a
        assert_equal [[deep_source, 'cycle', 'cycle', {}]], sink.each_concrete_input_connection.to_a

        FlexMock.use(deep_source) do |mock|
            mock.should_receive(:output_port).and_return(10).once
            assert_equal [deep_source, 'cycle'], composition.resolve_port(composition.model.find_output('out'))
            assert_equal 10, composition.output_port('out')
        end

        FlexMock.use(deep_sink) do |mock|
            mock.should_receive(:input_port).and_return(10).once
            assert_equal [deep_sink, 'cycle'], composition.resolve_port(composition.model.find_input('in'))
            assert_equal 10, composition.input_port('in')
        end
    end

    def test_instanciate_detects_ambiguous_service_mappings
        sys_model.data_source_type 'stereo', :interface => SystemTest::Stereo
        sys_model.data_source_type 'camera', :interface => SystemTest::CameraDriver

        camera_service = sys_model.get_data_service_type 'camera'

        SystemTest::StereoCamera.driver_for 'stereo'
        SystemTest::StereoCamera.data_service 'camera',
                :as => 'left', :slave_of => 'stereo'
        SystemTest::StereoCamera.data_service 'camera',
                :as => 'right', :slave_of => 'stereo'

        compo = sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add DataServices::Camera, :as => "image0"
            image1 = add DataServices::Camera, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end

        camera = SystemTest::StereoCamera.new
        assert_raises(AmbiguousServiceSelection) do
            compo.instanciate(orocos_engine,
                  :selection => {DataServices::Camera => SystemTest::StereoCamera})
        end
    end

    def test_instanciate_handles_port_mappings_for_implicit_service_selection
        sys_model.data_source_type 'stereo', :interface => SystemTest::Stereo
        sys_model.data_source_type 'camera', :interface => SystemTest::CameraDriver

        camera_service = sys_model.get_data_service_type 'camera'

        SystemTest::StereoCamera.driver_for 'stereo'
        SystemTest::StereoCamera.data_service 'camera',
                :as => 'left', :slave_of => 'stereo'

        compo = sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add DataServices::Camera, :as => "image0"
            image1 = add DataServices::Camera, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end

        camera = SystemTest::StereoCamera.new
        instance = compo.instanciate(orocos_engine,
            :selection => {DataServices::Camera => SystemTest::StereoCamera})

        processing_task = instance.child_from_role 'processing'
        image0_task = instance.child_from_role 'image0'
        image1_task = instance.child_from_role 'image1'
        assert_equal [['leftImage', 'leftImage']],
            image0_task[processing_task, Flows::DataFlow].keys
        assert_equal [['leftImage', 'rightImage']],
            image1_task[processing_task, Flows::DataFlow].keys
    end

    def test_instanciate_handles_explicit_device_selection_and_maps_the_ports_accordingly
        sys_model.data_source_type 'stereo', :interface => SystemTest::Stereo
        sys_model.data_source_type 'camera', :interface => SystemTest::CameraDriver

        camera_service = sys_model.get_data_service_type 'camera'

        SystemTest::StereoCamera.driver_for 'stereo'
        SystemTest::StereoCamera.data_service 'camera',
                :as => 'left', :slave_of => 'stereo'
        SystemTest::StereoCamera.data_service 'camera',
                :as => 'right', :slave_of => 'stereo'

        compo = sys_model.composition "Stereo" do
            stereo = add SystemTest::StereoProcessing, :as => 'processing'
            image0 = add DataServices::Camera, :as => "image0"
            image1 = add DataServices::Camera, :as => "image1"
            connect image0.image => stereo.leftImage
            connect image1.image => stereo.rightImage
        end

        camera = SystemTest::StereoCamera.new
        instance = compo.instanciate(orocos_engine,
            :selection => {'image0' => SystemTest::StereoCamera.stereo.left,
                'image1' => SystemTest::StereoCamera.stereo.right})

        processing_task = instance.child_from_role 'processing'
        image0_task = instance.child_from_role 'image0'
        image1_task = instance.child_from_role 'image1'
        assert_equal [['leftImage', 'leftImage']],
            image0_task[processing_task, Flows::DataFlow].keys
        assert_equal [['rightImage', 'rightImage']],
            image1_task[processing_task, Flows::DataFlow].keys
    end
end

