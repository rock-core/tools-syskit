BASE_DIR = File.expand_path( '../..', File.dirname(__FILE__))
APP_DIR = File.join(BASE_DIR, "test")

$LOAD_PATH.unshift BASE_DIR
require 'test/roby/common'

class TC_RobySpec_DataServiceModels < Test::Unit::TestCase
    include RobyPluginCommonTest

    needs_no_orogen_projects

    def test_data_service_type
        model = sys_model.data_service_type("Image")
        assert_equal(sys_model, model.system_model)
        assert_kind_of(DataServiceModel, model)
        assert(model < DataService)

        assert(sys_model.has_data_service?('Image'))
        assert_equal("Orocos::RobyPlugin::DataServices::Image", model.name)
        assert_same(model, Srv::Image)
    end

    def test_data_service_type_requires_constant_name
        assert_raises(ArgumentError) { sys_model.data_service_type("image") }
    end

    def test_data_service_task_model
        model = sys_model.data_service_type("Image")
        task  = model.task_model
        assert_same(task, model.task_model)
        assert(task.fullfills?(model))
    end

    def test_data_service_provides
        parent_model = sys_model.data_service_type("Test")
        model = sys_model.data_service_type("Image")
        model.provides parent_model
        assert(model.fullfills?(parent_model))
    end

    def test_data_service_provides_ports
        parent_model = sys_model.data_service_type("Test") do
            output_port "out", "/int"
        end
        model = sys_model.data_service_type("Image")
        model.provides parent_model
        assert(model.find_output_port("out"))
        assert(model.fullfills?(parent_model))
    end

    def test_data_service_provides_with_port_mappings
        parent_model = sys_model.data_service_type("Test") do
            output_port "out", "/int"
        end
        model = sys_model.data_service_type("Image") do
            output_port "new_out", "/int"
        end
        model.provides parent_model, 'out' => 'new_out'
        assert(!model.find_output_port("out"))
        assert(model.find_output_port("new_out"))
        assert(model.fullfills?(parent_model))
    end

    def test_data_service_provides_validates_port_mappings
        parent_model = sys_model.data_service_type("Test") do
            output_port "out", "/int"
        end

        model = sys_model.data_service_type("WrongMapping") do
            output_port "new_out", "/double"
        end
        assert_raises(SpecError) { model.provides(parent_model, 'out' => 'new_out') }

        model = sys_model.data_service_type("WrongType") do
            output_port "out", "/double"
        end
        assert_raises(SpecError) { model.provides parent_model }

        model = sys_model.data_service_type("WrongClass") do
            input_port "out", "/int"
        end
        assert_raises(SpecError) { model.provides parent_model }
    end


    def test_device_type
        model = sys_model.device_type("Camera")
        assert(sys_model.has_device?('Camera'))
        assert_same(model, DataSources::Camera)
        assert_equal("camera", model.name)
        assert_equal("#<DataSource: camera>", model.to_s)
        assert(data_service = DServ::Camera)
        assert(data_service != model)

        assert(model < data_service)
        assert(model < DataSource)
        assert(model < DataService)
    end

    def test_device_type_requires_proper_constant_name
        assert_raises(ArgumentError) { sys_model.device_type("camera") }
    end

    def test_task_data_service_declaration_using_type
        source_model = sys_model.data_service_type 'Image'
        task_model   = sys_model.task_context do
            provides source_model
        end

        assert(task_model.has_data_service?('image'))
        srv_image = task_model.find_data_service('image')

        assert(task_model.fullfills?(source_model))
        assert_equal(task_model, srv_image.component_model)
        assert_equal(source_model, srv_image.model)

        root_services = task_model.each_root_data_service.map(&:last)
        assert_equal(["image"], root_services.map(&:name))
        assert_equal([source_model], root_services.map(&:model))
    end

    def test_task_data_service_declaration_overloading
        parent_model = sys_model.data_service_type 'Parent'
        child_model  = sys_model.data_service_type 'Child' do
            provides parent_model
        end
        unrelated_model = sys_model.data_service_type 'Unrelated'

        parent_task = sys_model.task_context do
            provides parent_model, :as => 'service'
            provides parent_model, :as => 'parent_service'
        end
        child_task = sys_model.task_context(:child_of => parent_task)
        assert_raises(SpecError) do
            child_task.provides(unrelated_model, :as => 'service')
        end

        child_task.provides child_model, :as => 'child_service'
        child_task.provides child_model, :as => 'service'

        assert_equal [['service', child_model], ['parent_service', parent_model], ['child_service', child_model]].to_set,
            child_task.each_data_service.map { |_, ds| [ds.name, ds.model] }.to_set

        assert(parent_task.fullfills?(parent_model))
        assert(!parent_task.fullfills?(child_model))

        assert(child_task.fullfills?(parent_model))
        assert(child_task.fullfills?(child_model))
    end

    def test_task_driver_for_declares_driver
        image_model = sys_model.data_service_type 'Image'
        model = sys_model.task_context("CameraDriverTask")
        firewire_camera = model.driver_for('FirewireCamera') do
            provides Srv::Image
        end
        firewire_camera_model = firewire_camera.model

        assert_same(Orocos::RobyPlugin::Devices::FirewireCamera, firewire_camera_model)
        assert(firewire_camera.fullfills?(image_model))
        assert(model.fullfills?(firewire_camera_model))

        motors_service = model.driver_for('Motors')
        motors_model = motors_service.model
        assert_same(Orocos::RobyPlugin::Devices::Motors, motors_model)
        assert_equal(model.config_type_from_properties, motors_model.config_type)
    end

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

    def test_slave_data_service_declaration
        define_stereocamera

        task_model = SystemTest::StereoCamera

        assert_raises(SpecError) { task_model.provides Srv::Image, :slave_of => 'bla' }

        srv_left_image = task_model.find_data_service('stereo.left')
        assert_equal(Srv::Image, srv_left_image.model)
        assert_equal(task_model.find_data_service('stereo'), srv_left_image.master)
        assert_equal([], srv_left_image.each_input_port.to_a)
        assert_equal([task_model.find_output_port('leftImage')], srv_left_image.each_output_port.to_a)

        assert(task_model.fullfills?(Srv::Image))
        assert_equal(Srv::Image, task_model.find_data_service('stereo.left').model)
        assert_equal(Srv::Image, task_model.find_data_service('stereo.right').model)
    end

    def test_slave_data_service_enumeration
        define_stereocamera
        task_model = SystemTest::StereoCamera

        service_set = lambda do |enumerated_services|
            enumerated_services.map { |name, ds| [name, ds.model] }.to_set
        end
        srv_stereo = task_model.find_data_service('stereo')
        assert_equal([["left", Srv::Image], ["right", Srv::Image]].to_set,
                     service_set[task_model.each_slave_data_service(srv_stereo)])

        expected = [
            ["stereo", Dev::StereoCam],
            ["stereo.left", Srv::Image],
            ["stereo.right", Srv::Image]
        ]
        assert_equal(expected.to_set, service_set[task_model.each_data_service])
        assert_equal([["stereo", Dev::StereoCam]].to_set,
                     service_set[task_model.each_root_data_service])
        assert_equal([:stereo_name, :conf], task_model.arguments.to_a)
    end

    def test_provides_validates_ambiguities
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_service_type 'StereoCam' do
            output_port 'image', 'camera::Image'
        end
        assert_raises(InvalidProvides) do
            SystemTest::StereoProcessing.provides Srv::StereoCam
        end
    end

    def test_provides_validates_missing_ports
        Roby.app.load_orogen_project "system_test"
        stereo_model = sys_model.data_service_type 'StereoCam' do
            output_port 'image', '/double'
        end
        assert_raises(InvalidProvides) do
            SystemTest::StereoProcessing.provides Srv::StereoCam
        end
    end

    def test_data_service_can_merge
        define_stereocamera
        task_model = SystemTest::StereoCamera

        dummy_task_model = Dev::StereoCam.task_model

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        dummy_task = dummy_task_model.new
        parent.depends_on task0, :model => Dev::StereoCam
        parent.depends_on task1, :model => Dev::StereoCam
        parent.depends_on dummy_task, :model => Dev::StereoCam

        assert(task0.can_merge?(dummy_task))
        assert(task1.can_merge?(dummy_task))
        assert(task0.can_merge?(task1))
        assert(task1.can_merge?(task0))

        task1.stereo_name = 'back_stereo'
        assert(!task0.can_merge?(task1))
        assert(!task1.can_merge?(task0))
    end

    def test_using_data_service
        define_stereocamera

        plan.add(stereo = SystemTest::StereoProcessing.new)
        assert(!stereo.using_data_service?('stereo'))

        plan.add(camera = SystemTest::CameraDriver.new)
        camera.connect_ports stereo, ['image', 'leftImage'] => Hash.new
        assert(camera.using_data_service?('camera'))
        assert(!stereo.using_data_service?('stereo'))

        plan.remove_object(camera)
        plan.add(dem = SystemTest::DemBuilder.new)
        assert(!stereo.using_data_service?('stereo'))
        stereo.connect_ports dem, ['cloud', 'cloud'] => Hash.new
        assert(stereo.using_data_service?('stereo'))
    end

    def test_data_service_merge_data_flow
        Roby.app.load_orogen_project 'system_test'
        define_stereocamera

        stereo_model = SystemTest::StereoCamera
        camera_model = Srv::Image.task_model

        plan.add(parent = Roby::Task.new)
        task0 = stereo_model.new 'stereo_name' => 'front_stereo'
        task1 = camera_model.new
        task2 = SystemTest::CameraDriver.new 'camera_name' => 'front_camera'
        task3 = SystemTest::CameraDriver.new 'camera_name' => 'bottom_camera'
        parent.depends_on task0, :model => Srv::Image
        parent.depends_on task1, :model => Srv::Image
        parent.depends_on task2, :model => Srv::Image
        parent.depends_on task3, :model => Srv::Image

        # This one is ambiguous
        assert(!task0.can_merge?(task1))
        assert_raises(AmbiguousImplicitServiceSelection) { task0.merge(task1) }
        # This one is plainly impossible
        assert(!task1.can_merge?(task0))
        assert_raises(SpecError) { task1.merge(task0) }
        # This one cannot (device into service)
        assert(!task1.can_merge?(task2))
        assert_raises(SpecError) { task1.merge(task0) }
        # Cannot override arguments
        assert(!task3.can_merge?(task2))
        assert_raises(SpecError) { task1.merge(task0) }

        # Finally, one that is possible
        assert(task2.can_merge?(task1))
        task2.merge(task1)
    end

    def test_data_service_merge_arguments
        define_stereocamera
        task_model = SystemTest::StereoCamera

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => Srv::StereoProvider
        parent.depends_on task1, :model => Srv::StereoProvider

        task0.merge(task1)
        assert_equal("front_stereo", task0.arguments['stereo_name'])

        plan.add(parent = Roby::Task.new)
        task0 = task_model.new 'stereo_name' => 'front_stereo'
        task1 = task_model.new
        parent.depends_on task0, :model => Srv::StereoProvider
        parent.depends_on task1, :model => Srv::StereoProvider

        task1.merge(task0)
        assert_equal("front_stereo" , task1.arguments['stereo_name'])
    end

    def test_com_bus
        model = sys_model.com_bus_type 'Can', :message_type => '/can/Message'
        assert_same sys_model, model.system_model
        assert_equal 'Orocos::RobyPlugin::Devices::Can', model.name
        assert_equal '/can/Message', model.message_type

        instance_model = sys_model.task_context('CanDriver')
        can_service = instance_model.driver_for Dev::Can
        instance = instance_model.new
        assert_equal '/can/Message', can_service.model.message_type
    end

    def test_port_mapping
        define_stereocamera

        left  = SystemTest::StereoCamera.stereo.left
        right = SystemTest::StereoCamera.stereo.right

        assert_equal({'image' => 'leftImage'}, left.port_mappings_for_task)
        assert_equal({'image' => 'rightImage'}, right.port_mappings_for_task)
    end
end

