BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_DataSourceModels < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def test_data_source_type
        model = sys_model.data_source_type("image")
        assert_kind_of(DataSourceModel, model)
        assert(model < DataSource)

        assert(sys_model.has_interface?('image'))
        assert(!sys_model.has_composition?('image'))
        assert(!sys_model.has_device_driver?('image'))
        assert_equal("image", model.name)
        assert_equal("#<DataSource: image>", model.to_s)
        assert_same(model, IF::Image)
    end

    def test_data_source_task_model
        model = sys_model.data_source_type("image")
        task  = model.task_model
        assert_same(task, model.task_model)
        assert(task.fullfills?(model))
    end

    def test_data_source_submodel
        parent_model = sys_model.data_source_type("test")
        model = sys_model.data_source_type("image", :child_of => "test")
        assert_same(model, IF::Image)
        assert_equal 'image', model.name
        assert_kind_of(DataSourceModel, model)
        assert(model < parent_model)
        assert_same parent_model, model.parent_model
    end

    def test_data_source_interface_name
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_source_type("camera", :interface => "system_test::CameraDriver")
        assert_same(SystemTest::CameraDriver.orogen_spec, model.task_model.orogen_spec)
    end

    def test_data_source_interface_model
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_source_type("camera", :interface => SystemTest::CameraDriver)
        assert_same(SystemTest::CameraDriver.orogen_spec, model.task_model.orogen_spec)
    end

    def test_data_source_interface_definition
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_source_type("camera") do
            output_port 'image', 'camera/Image'
        end
        assert_equal 'camera', model.name
        assert(model.interface)
        assert(model.output_port('image'))
    end

    def test_data_source_submodel_interface
        Roby.app.load_orogen_project "system_test"
        parent_model = sys_model.data_source_type("image", :interface => SystemTest::CameraDriver)

        model = sys_model.data_source_type("imageFilter", :child_of => "image")
        assert(model.interface)
        assert_same(parent_model.interface, model.interface.superclass)
        assert(model.output_port('image'))
        assert_equal 'imageFilter', model.name

        model.interface do
            input_port 'image_in', 'camera/Image'
        end
        assert(model.input_port('image_in'))
    end

    def test_data_source_submodel_interface_validation
        Roby.app.load_orogen_project "system_test"
        parent_model = sys_model.data_source_type("image") do
            output_port 'image', 'camera/Image'
        end

        assert_raises(SpecError) do
            sys_model.data_source_type("imageFilter", :child_of => "image", :interface => SystemTest::CameraFilter)
        end
    end

    def test_device_type
        model = sys_model.device_type("camera")
        assert(sys_model.has_device_driver?('camera'))
        assert_same(model, DeviceDrivers::Camera)
        assert_equal("camera", model.name)
        assert_equal("#<DeviceDriver: camera>", model.to_s)
        assert(data_source = IF::Camera)
        assert(data_source != model)

        assert(model < data_source)
        assert(model < DeviceDriver)
        assert(model < DataSource)
    end

    def test_device_type_reuses_data_source
        source = sys_model.data_source_type("camera")
        model  = sys_model.device_type("camera")
        assert_same(source, IF::Camera)
    end

    def test_device_type_disabled_provides
        sys_model.device_type("camera", :provides => false)
        assert(!sys_model.has_interface?('camera'))
    end

    def test_device_type_explicit_provides_as_object
        source = sys_model.data_source_type("image")
        model  = sys_model.device_type("camera", :provides => source)
        assert(model < source)
        assert(! sys_model.has_interface?('camera'))
    end

    def test_device_type_explicit_provides_as_string
        source = sys_model.data_source_type("image")
        model  = sys_model.device_type("camera", :provides => 'image')
        assert(model < source)
        assert(! sys_model.has_interface?('camera'))
    end


    def test_task_data_source_declaration_using_type
        source_model = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source source_model
        end
        assert_raises(ArgumentError) { task_model.data_source('image') }

        assert(task_model.has_data_source?('image'))
        assert(task_model.main_data_source?('image'))

        assert(task_model < source_model)
        assert_equal(source_model, task_model.data_source_type('image'))
        assert_equal([["image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:image_name], task_model.arguments.to_a)
    end

    def test_task_data_source_declaration_default_name
        source_model = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'image'
        end
        assert_raises(ArgumentError) { task_model.data_source('image') }

        assert(task_model.has_data_source?('image'))
        assert(task_model.main_data_source?('image'))

        assert(task_model < source_model)
        assert_equal(source_model, task_model.data_source_type('image'))
        assert_equal([["image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:image_name], task_model.arguments.to_a)
    end

    def test_task_data_source_declaration_specific_name
        source_model       = sys_model.data_source_type 'image'
        task_model   = Class.new(TaskContext) do
            data_source 'image', :as => 'left_image'
        end
        assert_raises(ArgumentError) { task_model.data_source('image', :as => 'left_image') }

        assert(!task_model.has_data_source?('image'))
        assert(task_model.has_data_source?('left_image'))
        assert_raises(ArgumentError) { task_model.data_source_type('image') }

        assert(task_model.fullfills?(source_model))
        assert_equal(source_model, task_model.data_source_type('left_image'))
        assert_equal([["left_image", source_model]], task_model.each_root_data_source.to_a)
        assert_equal([:left_image_name], task_model.arguments.to_a)
    end

    def test_task_data_source_specific_model
        source_model = sys_model.data_source_type 'image'
        other_source = sys_model.data_source_type 'image2'
        task_model   = Class.new(TaskContext) do
            data_source other_source, :as => 'left_image'
        end
        assert_same(other_source, task_model.data_source_type('left_image'))
        assert(!(task_model < source_model))
        assert(task_model < other_source)
    end

    def test_task_data_source_declaration_inheritance
        parent_model = sys_model.data_source_type 'parent'
        child_model  = sys_model.data_source_type 'child', :child_of => parent_model
        unrelated_model = sys_model.data_source_type 'unrelated'

        parent_task = Class.new(TaskContext) do
            data_source 'parent'
            data_source 'parent', :as => 'specific_name'
        end
        child_task = Class.new(parent_task)
        assert_raises(SpecError) { child_task.data_source(unrelated_model, :as => 'specific_name') }

        child_task.data_source('child')
        child_task.data_source('child', :as => 'specific_name')

        assert_equal [['parent', child_model], ['specific_name', child_model]], child_task.each_data_source.to_a

        assert(parent_task.fullfills?(parent_model))
        assert(!parent_task.fullfills?(child_model))
        assert(child_task.fullfills?(parent_model))
        assert(child_task.fullfills?(child_model))
    end

    def test_task_data_source_overriden_by_device_driver
        source_model = sys_model.data_source_type 'image'
        driver_model = sys_model.device_type 'camera', :provides => 'image'

        parent_model   = Class.new(TaskContext) do
            data_source 'image', :as => 'left_image'
        end
        task_model = Class.new(parent_model)
        task_model.driver_for('camera', :as => 'left_image')

        assert(task_model.has_data_source?('left_image'))

        assert(task_model.fullfills?(source_model))
        assert(task_model.fullfills?(driver_model))
        assert_equal(driver_model, task_model.data_source_type('left_image'))
        assert_equal([["left_image", driver_model]], task_model.each_data_source.to_a)
        assert_equal([["left_image", driver_model]], task_model.each_root_data_source.to_a)
    end

    def test_task_driver_for_declares_driver
        image_model = sys_model.data_source_type 'image'
        model   = Class.new(TaskContext) do
            def orogen_spec; 'bla' end
        end
        model.system = sys_model

        firewire_camera = model.driver_for('FirewireCamera', :provides => image_model, :as => 'left_image')

        assert_same(Orocos::RobyPlugin::DeviceDrivers::FirewireCamera, firewire_camera)
        assert(firewire_camera < image_model)
        assert(model < firewire_camera)

        motors_model = model.driver_for('Motors')
        assert_same(Orocos::RobyPlugin::DeviceDrivers::Motors, motors_model)
        assert_equal(model.orogen_spec, motors_model.orogen_spec)
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
        assert_equal([["left_image", image_model], ["right_image", image_model]].to_set, task_model.each_child_data_source('stereo').to_set)

        expected = [
            ["stereo", stereo_model],
            ["stereo.left_image", image_model],
            ["stereo.right_image", image_model]
        ]
        assert_equal(expected.to_set, task_model.each_data_source.to_set)
        assert_equal([["stereo", stereo_model]], task_model.each_root_data_source.to_a)
        assert_equal([:stereo_name], task_model.arguments.to_a)
    end

    def test_data_source_find_matching_source
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_source_type 'stereocam'
        stereo_processing_model =
            sys_model.data_source_type 'stereoprocessing',
                :child_of => stereo_model,
                :interface => SystemTest::StereoCamera

        image_model  = sys_model.data_source_type 'image',
            :interface => SystemTest::CameraDriver

        task_model   = SystemTest::StereoCamera
        task_model.class_eval do
            data_source IF::Stereoprocessing, :as => 'stereo'
            data_source IF::Image, :as => 'left',  :slave_of => 'stereo'
            data_source IF::Image, :as => 'right', :slave_of => 'stereo'
        end

        assert_equal "stereo",     task_model.find_matching_source(stereo_model)
        assert_equal "stereo",     task_model.find_matching_source(stereo_processing_model)
        assert_raises(Ambiguous) { task_model.find_matching_source(image_model) }
        assert_equal "stereo.left", task_model.find_matching_source(image_model, "left")
        assert_equal "stereo.left", task_model.find_matching_source(image_model, "stereo.left")

        # Add fakes to trigger disambiguation by main/non-main
        task_model.data_source IF::Image, :as => 'left'
        assert_equal "left", task_model.find_matching_source(image_model)
        task_model.data_source IF::Image, :as => 'right'
        assert_raises(Ambiguous) { task_model.find_matching_source(image_model) }
        assert_equal "left", task_model.find_matching_source(image_model, "left")
        assert_equal "stereo.left", task_model.find_matching_source(image_model, "stereo.left")
    end

    def test_data_source_implemented_by
        Roby.app.load_orogen_project 'system_test'
        model0 = sys_model.data_source_type 'model0' do
            output_port 'image', 'camera/Image'
        end
        assert(model0.implemented_by?(SystemTest::CameraDriver))
        assert(!model0.implemented_by?(SystemTest::StereoCamera))
        assert(model0.implemented_by?(SystemTest::StereoCamera, true, 'left'))
        assert(model0.implemented_by?(SystemTest::StereoCamera, false, 'left'))
        assert(!model0.implemented_by?(SystemTest::StereoProcessing))
        assert(!model0.implemented_by?(SystemTest::StereoProcessing, true, 'left'))
        assert(!model0.implemented_by?(SystemTest::StereoProcessing, false, 'right'))

        model1 = sys_model.data_source_type 'model1' do
            input_port 'image', 'camera/Image'
        end
        assert(!model1.implemented_by?(SystemTest::CameraDriver))
        assert(!model1.implemented_by?(SystemTest::StereoCamera))
        assert(!model1.implemented_by?(SystemTest::StereoCamera, true, 'left'))
        assert(!model1.implemented_by?(SystemTest::StereoCamera, false, 'left'))
        assert(!model1.implemented_by?(SystemTest::StereoProcessing))
        assert(model1.implemented_by?(SystemTest::StereoProcessing, true, 'left'))
        assert(model1.implemented_by?(SystemTest::StereoProcessing, false, 'right'))
    end

    def test_data_source_guess
        Roby.app.load_orogen_project 'system_test'
        model0 = sys_model.data_source_type 'model0' do
            output_port 'image', 'camera/Image'
            output_port 'other', 'camera/Image'
        end

        model1 = sys_model.data_source_type 'model1' do
            output_port 'image', 'camera/Image'
        end
        assert !model0.guess_source_name(model1)

        model1.interface do
            output_port 'wrong', 'camera/Image'
        end
        assert !model0.guess_source_name(model1)

        model1.interface do
            output_port 'other', 'camera/Image'
        end
        assert_equal [''], model0.guess_source_name(model1)

        model1.interface do
            output_port 'leftImage', 'camera/Image'

            output_port 'imageRight', 'camera/Image'
            output_port 'otherRight', 'camera/Image'
        end
        assert_equal ['', 'right'], model0.guess_source_name(model1)

        model1.interface do
            output_port 'otherLeft', 'camera/Image'
        end
        assert_equal ['', 'left', 'right'], model0.guess_source_name(model1)
    end

    def test_data_source_instance
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_source_type 'stereocam', :interface => SystemTest::StereoCamera
        task_model   = SystemTest::StereoCamera
        task_model.data_source IF::Stereocam, :as => 'stereo'
        task = task_model.new 'stereo_name' => 'front_stereo'

        assert_equal("front_stereo", task.selected_data_source('stereo'))
        assert_equal(stereo_model, task.data_source_type('front_stereo'))
    end

    def test_data_source_instance_validation
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_source_type 'stereocam', :interface => SystemTest::StereoCamera
        assert_raises(SpecError) do
            SystemTest::CameraDriver.data_source IF::Stereocam, :as => 'stereo'
        end
    end

    def test_data_source_can_merge
        Roby.app.load_orogen_project 'system_test'
        task_model = SystemTest::StereoProcessing

        stereo_model = sys_model.data_source_type 'stereocam' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        task_model.data_source IF::Stereocam, :as => 'stereo'

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => IF::Stereocam
        parent.depends_on task1, :model => IF::Stereocam

        assert(task0.can_merge?(task1))
        assert(task1.can_merge?(task0))

        task1.stereo_name = 'back_stereo'
        assert(!task0.can_merge?(task1))
        assert(!task1.can_merge?(task0))
    end

    def test_using_data_source
        Roby.app.load_orogen_project 'system_test'

        sys_model.data_source_type 'stereocam' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        stereo_model = sys_model.data_source_type 'stereoprocessing',
            :child_of => 'stereocam' do
            input_port 'leftImage',  'camera/Image'
            input_port 'rightImage', 'camera/Image'
        end
        camera_model = sys_model.data_source_type 'camera' do
            output_port 'image', 'camera/Image'
        end
        SystemTest::StereoProcessing.data_source IF::Stereoprocessing, :as => 'stereo'
        SystemTest::CameraDriver.data_source IF::Camera

        plan.add(stereo = SystemTest::StereoProcessing.new)
        assert(!stereo.using_data_source?('stereo'))

        plan.add(camera = SystemTest::CameraDriver.new)
        camera.connect_ports stereo, ['image', 'leftImage'] => Hash.new
        assert(camera.using_data_source?('camera'))
        assert(stereo.using_data_source?('stereo'))

        plan.remove_object(camera)
        plan.add(dem = SystemTest::DemBuilder.new)
        assert(!stereo.using_data_source?('stereo'))
        stereo.connect_ports dem, ['cloud', 'cloud'] => Hash.new
        assert(stereo.using_data_source?('stereo'))
    end

    def test_data_source_merge_data_flow
        Roby.app.load_orogen_project 'system_test'

        sys_model.data_source_type 'camera', :interface => SystemTest::CameraDriver
        sys_model.data_source_type 'stereo', :interface => SystemTest::Stereo
        SystemTest::StereoCamera.class_eval do
            data_source IF::Stereo
            data_source IF::Camera, :as => 'left', :slave_of => 'stereo'
            data_source IF::Camera, :as => 'right', :slave_of => 'stereo'
        end
        stereo_model = SystemTest::StereoCamera

        SystemTest::CameraDriver.class_eval do
            data_source IF::Camera
        end
        camera_model = IF::Camera.task_model

        plan.add(parent = Roby::Task.new)
        task0 = stereo_model.new 'stereo_name' => 'front_stereo'
        task1 = camera_model.new 'camera_name' => 'front_stereo.left'
        parent.depends_on task0, :model => IF::Camera
        parent.depends_on task1, :model => IF::Camera

        assert(task0.can_merge?(task1))
        assert(!task1.can_merge?(task0))
        # Complex merge of data flow is actually not implemented. Make sure we
        # won't do anything stupid and clearly tell that to the user.
        assert_raises(NotImplementedError) { task0.merge(task1) }
    end

    def test_data_source_merge_arguments
        Roby.app.load_orogen_project 'system_test'

        stereo_model = sys_model.data_source_type 'camera', :interface => SystemTest::CameraDriver
        stereo_model = sys_model.data_source_type 'stereo', :interface => SystemTest::Stereo
        SystemTest::StereoCamera.class_eval do
            data_source 'stereo'
            data_source 'camera', :as => 'left', :slave_of => 'stereo'
            data_source 'camera', :as => 'right', :slave_of => 'stereo'
        end
        task_model = SystemTest::StereoCamera

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => IF::Stereo
        parent.depends_on task1, :model => IF::Stereo

        task0.merge(task1)
        assert_equal({ :stereo_name => "front_stereo" }, task0.arguments)

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => IF::Stereo
        parent.depends_on task1, :model => IF::Stereo

        task1.merge(task0)
        assert_equal({ :stereo_name => "front_stereo" }, task1.arguments)
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

        assert_equal("front_stereo", task.selected_data_source('stereo'))
        assert_equal("front_stereo.left", task.selected_data_source('stereo.left'))
        assert_equal("front_stereo.right", task.selected_data_source('stereo.right'))
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

    def test_com_bus
        model = sys_model.com_bus_type 'can', :message_type => '/can/Message'
        assert_equal 'can', model.name
        assert_equal '/can/Message', model.message_type

        instance_model = Class.new(TaskContext)
        instance_model.driver_for 'can'
        instance = instance_model.new
        assert_equal '/can/Message', instance.model.message_type
    end
end

