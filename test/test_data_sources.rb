BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_DataSourceModels < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def test_data_source
        model = sys_model.data_source_type("image")
        assert_kind_of(DataSourceModel, model)
        assert(model < DataSource)

        assert_equal("image", model.name)
        assert_equal("#<DataSource: image>", model.to_s)
    end

    def test_data_source_submodel
        parent_model = sys_model.data_source_type("test")
        model = sys_model.data_source_type("image", "test")
        assert_same(model, Roby.app.orocos_data_sources["image"])
        assert_kind_of(DataSourceModel, model)
        assert(model < parent_model)
    end

    def test_device_type
        model = sys_model.device_type("camera")
        assert_same(model, Roby.app.orocos_devices["camera"])
        assert_equal("camera", model.name)
        assert_equal("#<DeviceDriver: camera>", model.to_s)
        assert(data_source = Roby.app.orocos_data_sources["camera"])
        assert(data_source != model)

        assert(model < data_source)
        assert(model < DeviceDriver)
        assert(model < DataSource)
    end

    def test_device_type_reuses_data_source
        source = sys_model.data_source_type("camera")
        model  = sys_model.device_type("camera")
        assert_same(source, Roby.app.orocos_data_sources['camera'])
    end

    def test_device_type_disabled_provides
        sys_model.device_type("camera", :provides => nil)
        assert(!Roby.app.orocos_data_sources['camera'])
    end

    def test_device_type_explicit_provides_as_object
        source = sys_model.data_source_type("image")
        model  = sys_model.device_type("camera", :provides => source)
        assert(model < source)
        assert(! Roby.app.orocos_data_sources['camera'])
    end

    def test_device_type_explicit_provides_as_string
        source = sys_model.data_source_type("image")
        model  = sys_model.device_type("camera", :provides => 'image')
        assert(model < source)
        assert(! Roby.app.orocos_data_sources['camera'])
    end


    def test_task_data_source_declaration_default_name
        source_model = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'image'
        end
        assert_raises(SpecError) { task_model.data_source('image') }

        assert(task_model.has_data_source?('image'))

        assert(task_model < source_model)
        assert_equal(source_model, task_model.data_source_type('image'))
        assert_equal([["image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:image_name], task_model.arguments.to_a)
    end

    def test_task_data_source_declaration_specific_name
        source_model = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'image', :as => 'left_image'
        end
        assert_raises(SpecError) { task_model.data_source('image', :as => 'left_image') }

        assert(!task_model.has_data_source?('image'))
        assert(task_model.has_data_source?('left_image'))
        assert_raises(ArgumentError) { task_model.data_source_type('image') }

        assert(task_model.fullfills?(source_model))
        assert_equal(source_model, task_model.data_source_type('left_image'))
        assert_equal([["left_image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:left_image_name], task_model.arguments.to_a)
    end

    def test_task_data_source_declaration_inheritance
        source_model = sys_model.data_source_type 'image'
        parent_model   = Class.new(TaskContext) do
            data_source 'image', :as => 'left_image'
        end
        task_model = Class.new(parent_model)
        assert_raises(SpecError) { task_model.data_source('image', :as => 'left_image') }

        assert(task_model.has_data_source?('left_image'))

        assert(task_model.fullfills?(source_model))
        assert_equal(source_model, task_model.data_source_type('left_image'))
        assert_equal([["left_image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:left_image_name], task_model.arguments.to_a)
    end

    def test_slave_data_source_declaration
        stereo_model = sys_model.data_source_type 'stereocam'
        image_model  = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'stereocam', :as => 'stereo'
            data_source 'image', :as => 'left_image', :slave_of => 'stereo'
            data_source 'image', :as => 'right_image', :slave_of => 'stereo'
        end

        assert_raises(SpecError) { task_model.data_source 'image', :slave_of => 'bla' }

        assert(task_model.fullfills?(image_model))
        assert_equal(image_model, task_model.data_source_type('stereo.left_image'))
        assert_equal(image_model, task_model.data_source_type('stereo.right_image'))

        expected = [
            ["stereo", stereo_model],
            ["stereo.left_image", image_model],
            ["stereo.right_image", image_model]
        ]
        assert_equal(expected.to_set, task_model.each_data_source.to_set)
        assert_equal([["stereo", stereo_model]], task_model.each_root_data_source.to_a)
        assert_equal([:stereo_name], task_model.arguments.to_a)
    end

    def test_data_source_instance
        stereo_model = sys_model.data_source_type 'stereocam'
        task_model   = Class.new(TaskContext) do
            data_source 'stereocam', :as => 'stereo'
        end
        task = task_model.new 'stereo_name' => 'front_stereo'

        assert_equal("front_stereo", task.data_source_name('stereo'))
        assert_equal(stereo_model, task.data_source_type('front_stereo'))
    end

    def test_slave_data_source_instance
        stereo_model = sys_model.data_source_type 'stereocam'
        image_model  = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'stereocam', :as => 'stereo'
            data_source 'image', :as => 'left', :slave_of => 'stereo'
            data_source 'image', :as => 'right', :slave_of => 'stereo'
        end
        task = task_model.new 'stereo_name' => 'front_stereo'

        assert_equal("front_stereo", task.data_source_name('stereo'))
        assert_equal("front_stereo.left", task.data_source_name('stereo.left'))
        assert_equal("front_stereo.right", task.data_source_name('stereo.right'))
        assert_equal(stereo_model, task.data_source_type('front_stereo'))
        assert_equal(image_model, task.data_source_type("front_stereo.left"))
        assert_equal(image_model, task.data_source_type("front_stereo.right"))
    end

    def test_driver_for
        image_model  = sys_model.data_source_type 'image'
        device_model = sys_model.device_type 'camera', :provides => 'image'
        device_driver = Class.new(TaskContext) do
            driver_for 'camera'
        end

        assert(device_driver.fullfills?(device_model))
        assert(device_driver < image_model)
        assert(device_driver.fullfills?(image_model))
        assert(device_driver.has_data_source?('camera'))
        assert_equal(device_model, device_driver.data_source_type('camera'))
    end

    def test_driver_for_unknown_device_type
        sys_model.data_source_type 'camera'
        model = Class.new(TaskContext)
        assert_raises(ArgumentError) do
            model.driver_for 'camera'
        end
    end

    def test_task_model
        device_model = sys_model.device_type 'camera'
        task_model = Class.new(TaskContext)
        Roby.app.orocos_tasks['fake'] = task_model
        task_model.driver_for 'camera'

        assert_same(task_model, device_model.task_model)
    end

    def test_task_model_no_match
        device_model = sys_model.device_type 'camera'
        task_model = Class.new(TaskContext)
        assert_raises(SpecError) { device_model.task_model }
    end

    def test_task_model_ambiguous
        device_model = sys_model.device_type 'camera'
        task_model0 = Class.new(TaskContext)
        Roby.app.orocos_tasks['fake0'] = task_model0
        task_model0.driver_for 'camera'
        task_model1 = Class.new(TaskContext)
        Roby.app.orocos_tasks['fake1'] = task_model0
        task_model1.driver_for 'camera'

        assert_raises(Ambiguous) { device_model.task_model }
    end
end

