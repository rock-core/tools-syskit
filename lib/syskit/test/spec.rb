module Syskit
    module Test
        class Spec < Roby::Test::Spec
            include Test::Base

            def setup
                Syskit.conf.register_process_server('stubs', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader), "")
                super
                Syskit.conf.disable_logging
            end

            def teardown
                if !passed? && app.public_logs?
                    dataflow, hierarchy = __full_name__ + "-partial-dataflow.svg", __full_name__ + "-partial-hierarchy.svg"
                    dataflow, hierarchy = [dataflow, hierarchy].map do |filename|
                        filename.gsub("/", "_")
                    end
                    Graphviz.new(plan).to_file('dataflow', 'svg', File.join(app.log_dir, dataflow))
                    Graphviz.new(plan).to_file('hierarchy', 'svg', File.join(app.log_dir, hierarchy))
                end

                super

            ensure
                Syskit.conf.remove_process_server('stubs')
            end

            # Create a stub device
            #
            # @param [String] dev_name the name of the created device
            # @return [Syskit::Component] the device driver task
            def stub_syskit_driver(dev_m, options = Hash.new)
                robot = Syskit::Robot::RobotDefinition.new
                device = robot.device(dev_m, options)
                task_srv = device.driver_model
                stub_syskit_deployment_model(task_srv.component_model, device.name)
                task_srv.component_model.with_arguments("#{task_srv.name}_dev" => device)
            end

            # Create a stub device task attached to a given communication bus
            #
            # This is meant to be used to test the integration of specific com
            # busses. The driver task from the communication bus is expected to
            # exist, while the driver task for the device is stubbed as well.
            #
            # The bus is called 'bus'
            #
            # @param [String] dev_name the name of the created device
            # @return [Syskit::Component] the device driver task
            def stub_syskit_attached_device(bus_m, dev_name = 'dev')
                robot = Syskit::Robot::RobotDefinition.new
                dev_m = Syskit::Device.new_submodel(:name => "StubDevice")
                driver_m = Syskit::TaskContext.new_submodel(:name => "StubDriver") do
                    input_port 'bus_in', bus_m.message_type
                    output_port 'bus_out', bus_m.message_type
                    provides bus_m.client_srv, :as => 'can'
                    driver_for dev_m, :as => 'dev'
                end
                stub_syskit_deployment_model(driver_m, 'driver_task')
                bus = robot.com_bus bus_m, :as => 'bus'
                stub_syskit_deployment_model(bus.driver_model, 'bus_task')
                robot.device(dev_m, :as => dev_name).
                    attach_to(bus)
            end

            def plan; Roby.plan end

            def flexmock(*args)
                # If we build a partial mock, define the mock methods from
                # Syskit::Test::FlexMockExtension
                result = super
                if proxy = result.instance_variable_get("@flexmock_proxy")
                    proxy.add_mock_method(:should_receive_operation)
                end
                result
            end
        end
    end
end

