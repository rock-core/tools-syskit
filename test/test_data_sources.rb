BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_DataServiceModels < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def test_data_service_type
        model = sys_model.data_service_type("image")
        assert_kind_of(DataServiceModel, model)
        assert(model < DataService)

        assert(sys_model.has_data_service?('image'))
        assert(!sys_model.has_composition?('image'))
        assert(!sys_model.has_data_source?('image'))
        assert_equal("image", model.name)
        assert_equal("#<DataService: image>", model.to_s)
        assert_same(model, DServ::Image)
    end

    def test_data_service_task_model
        model = sys_model.data_service_type("image")
        task  = model.task_model
        assert_same(task, model.task_model)
        assert(task.fullfills?(model))
    end

    def test_data_service_submodel
        parent_model = sys_model.data_service_type("test")
        model = sys_model.data_service_type("image", :child_of => "test")
        assert_same(model, DServ::Image)
        assert_equal 'image', model.name
        assert_kind_of(DataServiceModel, model)
        assert(model < parent_model)
        assert_same parent_model, model.parent_model
    end

    def test_data_service_interface_name
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_service_type("camera", :interface => "system_test::CameraDriver")
        assert_same(SystemTest::CameraDriver.orogen_spec, model.task_model.orogen_spec)
    end

    def test_data_service_interface_model
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_service_type("camera", :interface => SystemTest::CameraDriver)
        assert_same(SystemTest::CameraDriver.orogen_spec, model.task_model.orogen_spec)
    end

    def test_data_service_interface_definition
        Roby.app.load_orogen_project "system_test"
        model = sys_model.data_service_type("camera") do
            output_port 'image', 'camera/Image'
        end
        assert_equal 'camera', model.name
        assert(model.interface)
        assert(model.output_port('image'))
    end

    def test_data_service_submodel_interface
        Roby.app.load_orogen_project "system_test"
        parent_model = sys_model.data_service_type("image", :interface => SystemTest::CameraDriver)

        model = sys_model.data_service_type("imageFilter", :child_of => "image")

        assert(model <= parent_model)
        assert(model.interface)
        assert_same(parent_model.interface, model.interface.superclass)
        assert(model.output_port('image'))
        assert_equal 'imageFilter', model.name

        model.interface do
            input_port 'image_in', 'camera/Image'
        end
        assert(model.input_port('image_in'))
    end

    def test_data_service_submodel_interface_validation
        Roby.app.load_orogen_project "system_test"
        parent_model = sys_model.data_service_type("image") do
            output_port 'image', 'camera/Image'
        end

        assert_raises(SpecError) do
            sys_model.data_service_type("imageFilter", :child_of => "image", :interface => SystemTest::CameraFilter)
        end
    end

    def test_data_source_type
        model = sys_model.data_source_type("camera")
        assert(sys_model.has_data_source?('camera'))
        assert_same(model, DataSources::Camera)
        assert_equal("camera", model.name)
        assert_equal("#<DataSource: camera>", model.to_s)
        assert(data_service = DServ::Camera)
        assert(data_service != model)

        assert(model < data_service)
        assert(model < DataSource)
        assert(model < DataService)
    end

    def test_data_source_type_reuses_data_service
        source = sys_model.data_service_type("camera") do
            output_port 'test', 'int'
        end

        model  = sys_model.data_source_type("camera")
        assert(model < source)
        assert_equal(source.orogen_spec, model.orogen_spec.superclass)
        assert_same(source, DServ::Camera)
    end

    def test_data_source_type_disabled_provides
        sys_model.data_source_type("camera", :provides => false)
        assert(!sys_model.has_data_service?('camera'))
    end

    def test_data_source_type_explicit_provides_as_object
        source = sys_model.data_service_type("image") do
            output_port 'test', 'int'
        end
        model  = sys_model.data_source_type("camera", :provides => source)
        assert(model < source)
        assert_equal(source.orogen_spec, model.orogen_spec.superclass)
        assert(! sys_model.has_data_service?('camera'))
    end

    def test_data_source_type_explicit_provides_as_string
        source = sys_model.data_service_type("image")
        model  = sys_model.data_source_type("camera", :provides => 'image')
        assert(model < source)
        assert(! sys_model.has_data_service?('camera'))
    end


    def test_task_data_service_declaration_using_type
        source_model = sys_model.data_service_type 'image'
        task_model   = Class.new(TaskContext) do
            data_service source_model
        end
        assert_raises(ArgumentError) { task_model.data_service('image') }

        assert(task_model.has_data_service?('image'))
        srv_image = task_model.find_data_service('image')
        assert(srv_image.main?)

        assert(task_model < source_model)
        assert_equal(task_model, srv_image.component_model)
        assert_equal(source_model, srv_image.model)
        assert_equal(source_model, task_model.data_service_type('image'))

        root_services = task_model.each_root_data_service.map(&:last)
        assert_equal(["image"], root_services.map(&:name))
        assert_equal([source_model], root_services.map(&:model))
    end

    def test_task_data_service_declaration_default_name
        source_model = sys_model.data_service_type 'image'
        task_model   = Class.new(TaskContext) do
            data_service 'image'
        end
        assert_raises(ArgumentError) { task_model.data_service('image') }

        assert(task_model.has_data_service?('image'))
        srv_image = task_model.find_data_service('image')
        assert(srv_image.main?)

        assert(task_model < source_model)
        assert_equal(task_model, srv_image.component_model)
        assert_equal(source_model, srv_image.model)
        assert_equal(source_model, task_model.data_service_type('image'))

        root_services = task_model.each_root_data_service.to_a
        assert_equal(["image"], root_services.map(&:first))
        assert_equal([source_model], root_services.map(&:last).map(&:model))
    end

    def test_task_data_service_declaration_specific_name
        source_model       = sys_model.data_service_type 'image'
        task_model   = Class.new(TaskContext) do
            data_service 'image', :as => 'left_image'
        end
        assert_raises(ArgumentError) { task_model.data_service('image', :as => 'left_image') }

        assert(!task_model.has_data_service?('image'))
        assert(task_model.has_data_service?('left_image'))
        assert_raises(ArgumentError) { task_model.data_service_type('image') }

        assert(task_model.fullfills?(source_model))
        assert_equal(source_model, task_model.data_service_type('left_image'))

        root_services = task_model.each_root_data_service.to_a
        assert_equal(["left_image"], root_services.map(&:first))
        assert_equal([source_model], root_services.map(&:last).map(&:model))
    end

    def test_task_data_service_specific_model
        source_model = sys_model.data_service_type 'image'
        other_source = sys_model.data_service_type 'image2'
        task_model   = Class.new(TaskContext) do
            data_service other_source, :as => 'left_image'
        end
        assert_same(other_source, task_model.data_service_type('left_image'))
        assert(!(task_model < source_model))
        assert(task_model < other_source)
    end

    def test_task_data_service_declaration_inheritance
        parent_model = sys_model.data_service_type 'parent'
        child_model  = sys_model.data_service_type 'child', :child_of => parent_model
        unrelated_model = sys_model.data_service_type 'unrelated'

        parent_task = Class.new(TaskContext) do
            data_service 'parent'
            data_service 'parent', :as => 'specific_name'
        end
        child_task = Class.new(parent_task)
        assert_raises(SpecError) { child_task.data_service(unrelated_model, :as => 'specific_name') }

        child_task.data_service('child')
        child_task.data_service('child', :as => 'specific_name')

        assert_equal [['parent', child_model], ['specific_name', child_model]],
            child_task.each_data_service.map { |_, ds| [ds.name, ds.model] }

        assert(parent_task.fullfills?(parent_model))
        assert(!parent_task.fullfills?(child_model))
        assert(child_task.fullfills?(parent_model))
        assert(child_task.fullfills?(child_model))
    end

    def test_task_data_service_overriden_by_data_source
        source_model = sys_model.data_service_type 'image'
        driver_model = sys_model.data_source_type 'camera', :provides => 'image'

        parent_model   = Class.new(TaskContext) do
            data_service 'image', :as => 'left_image'
        end
        task_model = Class.new(parent_model)
        task_model.driver_for('camera', :as => 'left_image')

        assert(task_model.has_data_service?('left_image'))

        assert(task_model.fullfills?(source_model))
        assert(task_model.fullfills?(driver_model))
        assert_equal(driver_model, task_model.data_service_type('left_image'))

        all_services = task_model.each_data_service.map(&:last)
        assert_equal(["left_image"], all_services.map(&:name))
        assert_equal([driver_model], all_services.map(&:model))

        root_services = task_model.each_root_data_service.map(&:last)
        assert_equal(["left_image"], root_services.map(&:name))
        assert_equal([driver_model], root_services.map(&:model))
    end

    def test_task_driver_for_declares_driver
        image_model = sys_model.data_service_type 'image'

        fake_spec = Roby.app.main_orogen_project.task_context 'FakeSpec'
        model   = Class.new(TaskContext)
        model.instance_variable_set(:@orogen_spec, fake_spec)
        model.system = sys_model

        firewire_camera = model.driver_for('FirewireCamera', :provides => image_model, :as => 'left_image')

        assert_same(Orocos::RobyPlugin::DataSources::FirewireCamera, firewire_camera)
        assert(firewire_camera < image_model)
        assert(model < firewire_camera)

        motors_model = model.driver_for('Motors')
        assert_same(Orocos::RobyPlugin::DataSources::Motors, motors_model)
        assert_equal(model.orogen_spec, motors_model.orogen_spec.superclass)
    end

    def define_stereocamera
        Roby.app.load_orogen_project "system_test"
        stereo_processing =
            sys_model.data_service_type 'stereoprocessing'
        stereo_cam = sys_model.data_source_type 'stereocam',
                :interface => SystemTest::StereoCamera,
                :provides => stereo_processing
        image  = sys_model.data_service_type 'image',
            :interface => SystemTest::CameraDriver
        task_model   = SystemTest::StereoCamera
        task_model.driver_for stereo_cam, :as => 'stereo', :main => true
        task_model.data_service DServ::Image, :as => 'left',  :slave_of => 'stereo'
        task_model.data_service DServ::Image, :as => 'right', :slave_of => 'stereo'

        return stereo_processing, stereo_cam, image, task_model
    end

    def test_slave_data_service_declaration
        stereo_processing, stereo_cam, image, task_model = define_stereocamera

        assert_raises(SpecError) { task_model.data_service 'image', :slave_of => 'bla' }

        srv_left_image = task_model.find_data_service('stereo.left')
        assert_equal(image, srv_left_image.model)
        assert_equal(task_model.find_data_service('stereo'), srv_left_image.master)
        assert_equal([], srv_left_image.each_input.to_a)
        assert_equal([task_model.output_port('leftImage')], srv_left_image.each_output.to_a)

        assert(task_model.fullfills?(image))
        assert_equal(image, task_model.data_service_type('stereo.left'))
        assert_equal(image, task_model.data_service_type('stereo.right'))
    end

    def test_slave_data_service_enumeration
        stereo_processing, stereo_cam, image_model, task_model = define_stereocamera

        service_set = lambda do |enumerated_services|
            enumerated_services.map { |name, ds| [name, ds.model] }.to_set
        end
        srv_stereo = task_model.find_data_service('stereo')
        assert_equal([["left", image_model], ["right", image_model]].to_set,
                     service_set[task_model.each_slave_data_service(srv_stereo)])

        stereo_driver_model = Orocos::RobyPlugin::DataSources::Stereocam
        expected = [
            ["stereo", stereo_driver_model],
            ["stereo.left", image_model],
            ["stereo.right", image_model]
        ]
        assert_equal(expected.to_set, service_set[task_model.each_data_service])
        assert_equal([["stereo", stereo_driver_model]].to_set,
                     service_set[task_model.each_root_data_service])
        assert_equal([:stereo_name, :com_bus], task_model.arguments.to_a)
    end

    def test_data_service_find_matching_service
        stereo_processing, stereo_cam, image_model, task_model = define_stereocamera

        srv_stereo    = task_model.find_data_service('stereo')
        srv_img_left  = task_model.find_data_service('stereo.left')
        srv_img_right = task_model.find_data_service('stereo.right')

        assert_equal srv_stereo,   task_model.find_matching_service(stereo_cam)
        assert_equal srv_stereo,   task_model.find_matching_service(stereo_processing)
        assert_raises(Ambiguous) { task_model.find_matching_service(image_model) }
        assert_equal srv_img_left, task_model.find_matching_service(image_model, "left")
        assert_equal srv_img_left, task_model.find_matching_service(image_model, "stereo.left")

        # Add fakes to trigger disambiguation by main/non-main
        srv_left = task_model.data_service DServ::Image, :as => 'left', 'image' => 'leftImage'
        assert_equal srv_left, task_model.find_matching_service(image_model)
        task_model.data_service DServ::Image, :as => 'right', 'image' => 'rightImage'
        assert_raises(Ambiguous) { task_model.find_matching_service(image_model) }
        assert_equal srv_left, task_model.find_matching_service(image_model, "left")
        assert_equal srv_img_left, task_model.find_matching_service(image_model, "stereo.left")
    end

    def test_data_service_guess
        Roby.app.load_orogen_project 'system_test'
        model0 = sys_model.data_service_type 'model0' do
            output_port 'image', 'camera/Image'
            output_port 'other', 'camera/Image'
        end

        model1 = sys_model.data_service_type 'model1' do
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
        stereo_model = sys_model.data_service_type 'stereocam', :interface => SystemTest::StereoCamera
        task_model   = SystemTest::StereoCamera
        task_model.data_service DServ::Stereocam, :as => 'stereo', :main => true
        task = task_model.new 'stereo_name' => 'front_stereo'

        source = task_model.find_data_service('stereo')
        assert_equal("front_stereo", task.selected_data_source(source))
        assert_equal(stereo_model, task.data_service_type('front_stereo'))
    end

    def test_data_service_instance_validation
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_service_type 'stereocam', :interface => SystemTest::StereoCamera
        assert_raises(SpecError) do
            SystemTest::CameraDriver.data_service DServ::Stereocam, :as => 'stereo'
        end
    end

    def test_data_service_can_merge
        Roby.app.load_orogen_project 'system_test'
        task_model = SystemTest::StereoProcessing

        stereo_model = sys_model.data_service_type 'stereocam' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        dummy_task_model = stereo_model.task_model
        task_model.driver_for 'Stereocam', :as => 'stereo', :main => true

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        dummy_task = dummy_task_model.new
        parent.depends_on task0, :model => DServ::Stereocam
        parent.depends_on task1, :model => DServ::Stereocam
        parent.depends_on dummy_task, :model => DServ::Stereocam

        assert(task0.can_merge?(dummy_task))
        assert(task1.can_merge?(dummy_task))
        assert(task0.can_merge?(task1))
        assert(task1.can_merge?(task0))

        task1.stereo_name = 'back_stereo'
        assert(!task0.can_merge?(task1))
        assert(!task1.can_merge?(task0))
    end

    def test_using_data_service
        Roby.app.load_orogen_project 'system_test'

        sys_model.data_service_type 'stereocam' do
            output_port 'disparity', 'camera/Image'
            output_port 'cloud', 'base/PointCloud3D'
        end
        stereo_model = sys_model.data_service_type 'stereoprocessing',
            :child_of => 'stereocam' do
            input_port 'leftImage',  'camera/Image'
            input_port 'rightImage', 'camera/Image'
        end
        camera_model = sys_model.data_service_type 'camera' do
            output_port 'image', 'camera/Image'
        end
        SystemTest::StereoProcessing.data_service DServ::Stereoprocessing, :as => 'stereo', :main => true
        SystemTest::CameraDriver.data_service DServ::Camera

        plan.add(stereo = SystemTest::StereoProcessing.new)
        assert(!stereo.using_data_service?('stereo'))

        plan.add(camera = SystemTest::CameraDriver.new)
        camera.connect_ports stereo, ['image', 'leftImage'] => Hash.new
        assert(camera.using_data_service?('camera'))
        assert(stereo.using_data_service?('stereo'))

        plan.remove_object(camera)
        plan.add(dem = SystemTest::DemBuilder.new)
        assert(!stereo.using_data_service?('stereo'))
        stereo.connect_ports dem, ['cloud', 'cloud'] => Hash.new
        assert(stereo.using_data_service?('stereo'))
    end

    def test_data_service_merge_data_flow
        Roby.app.load_orogen_project 'system_test'

        sys_model.data_service_type 'camera', :interface => SystemTest::CameraDriver
        sys_model.data_service_type 'stereo', :interface => SystemTest::Stereo
        SystemTest::StereoCamera.data_service DServ::Stereo
        SystemTest::StereoCamera.data_service DServ::Camera, :as => 'left', :slave_of => 'stereo'
        SystemTest::StereoCamera.data_service DServ::Camera, :as => 'right', :slave_of => 'stereo'
        stereo_model = SystemTest::StereoCamera

        SystemTest::CameraDriver.data_service DServ::Camera
        camera_model = DServ::Camera.task_model

        plan.add(parent = Roby::Task.new)
        task0 = stereo_model.new 'stereo_name' => 'front_stereo'
        task1 = camera_model.new 'camera_name' => 'front_stereo.left'
        parent.depends_on task0, :model => DServ::Camera
        parent.depends_on task1, :model => DServ::Camera

        assert_raises(NotImplementedError) { assert(task0.can_merge?(task1)) }
        assert(!task1.can_merge?(task0))
        # Complex merge of data flow is actually not implemented. Make sure we
        # won't do anything stupid and clearly tell that to the user.
        assert_raises(NotImplementedError) { task0.merge(task1) }
    end

    def test_data_service_merge_arguments
        Roby.app.load_orogen_project 'system_test'

        stereo_model = sys_model.data_service_type 'camera', :interface => SystemTest::CameraDriver
        stereo_model = sys_model.data_service_type 'stereo', :interface => SystemTest::Stereo
        SystemTest::StereoCamera.class_eval do
            data_service 'stereo'
            data_service 'camera', :as => 'left', :slave_of => 'stereo'
            data_service 'camera', :as => 'right', :slave_of => 'stereo'
        end
        task_model = SystemTest::StereoCamera

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => DServ::Stereo
        parent.depends_on task1, :model => DServ::Stereo

        task0.merge(task1)
        assert_equal({ :stereo_name => "front_stereo" }, task0.arguments)

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => DServ::Stereo
        parent.depends_on task1, :model => DServ::Stereo

        task1.merge(task0)
        assert_equal({ :stereo_name => "front_stereo" }, task1.arguments)
    end

    def test_slave_data_service_instance
        stereo_model = sys_model.data_service_type 'stereocam'
        image_model  = sys_model.data_service_type 'image'

        srv_stereo, srv_img_left, srv_img_right = nil
        task_model   = Class.new(TaskContext) do
            srv_stereo    = data_service 'stereocam', :as => 'stereo'
            srv_img_left  = data_service 'image', :as => 'left', :slave_of => 'stereo'
            srv_img_right = data_service 'image', :as => 'right', :slave_of => 'stereo'
        end
        task = task_model.new 'stereo_name' => 'front_stereo'

        assert_same srv_stereo, srv_img_left.master
        assert_same srv_stereo, srv_img_right.master

        assert_equal("front_stereo",       task.selected_data_source('stereo'))
        assert_equal("front_stereo.left",  task.selected_data_source('stereo.left'))
        assert_equal("front_stereo.right", task.selected_data_source('stereo.right'))

        assert_equal("front_stereo",       task.selected_data_source(srv_stereo))
        assert_equal("front_stereo.left",  task.selected_data_source(srv_img_left))
        assert_equal("front_stereo.right", task.selected_data_source(srv_img_right))
        assert_equal(srv_stereo.model, task.data_service_type('front_stereo'))
        assert_equal(srv_img_left.model, task.data_service_type("front_stereo.left"))
        assert_equal(srv_img_right.model, task.data_service_type("front_stereo.right"))
    end

    def test_driver_for
        Roby.app.load_orogen_project "system_test"
        image_model  = sys_model.data_service_type 'image' do
            output_port 'image', 'camera/Image'
        end
        device_model = sys_model.data_source_type 'camera', :provides => 'image'
        assert_equal image_model.orogen_spec, device_model.orogen_spec.superclass

        SystemTest::CameraDriver.driver_for 'camera'
        data_source = SystemTest::CameraDriver

        assert(data_source.fullfills?(device_model))
        assert(data_source < image_model)
        assert(data_source.fullfills?(image_model))
        assert(data_source.has_data_service?('camera'))
        assert_equal(device_model, data_source.data_service_type('camera'))
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

