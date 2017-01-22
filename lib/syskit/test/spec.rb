module Syskit
    module Test
        Roby::Test::Spec.roby_plan_with(Component.match.with_child(InstanceRequirementsTask)) do |task, stub: true, **|
            if stub
                syskit_stub_and_deploy(task)
            else
                syskit_deploy(task)
            end
        end

        class Spec < Roby::Test::Spec
            include Test::Base

            def setup
                unplug_requirement_modifications
                Syskit.conf.register_process_server(
                    'stubs', Orocos::RubyTasks::ProcessManager.new(Roby.app.default_loader, task_context_class: Orocos::RubyTasks::StubTaskContext), "", host_id: 'syskit')
                super
                Syskit.conf.logs.disable_conf_logging
                Syskit.conf.logs.disable_port_logging
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

            # Override the task model that should by default in tests such as
            # {#is_configurable}. This is used mainly in case the task model
            # under test is abstract
            def self.use_syskit_model(model)
                @subject_syskit_model = model
            end

            # Returns the syskit model under test
            #
            # It is delegated to self.class.subject_syskit_model by default
            def subject_syskit_model
                self.class.subject_syskit_model
            end

            # Returns the syskit model under test
            def self.subject_syskit_model
                if @subject_syskit_model
                    return @subject_syskit_model
                end
                parent = superclass
                if parent.respond_to?(:subject_syskit_model)
                    parent.subject_syskit_model
                else
                    raise ArgumentError, "no subject syskit model found"
                end
            end

            # Create a stub driver model
            #
            # @param [String] dev_name the name of the created device
            # @return [Syskit::Component] the device driver task
            def syskit_stub_driver_model(dev_m, options = Hash.new)
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
            def syskit_stub_attached_device_model(bus_m, dev_name = 'dev')
                robot = Syskit::Robot::RobotDefinition.new
                dev_m = Syskit::Device.new_submodel(name: "StubDevice")
                driver_m = Syskit::TaskContext.new_submodel(name: "StubDriver") do
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
        end
    end
end

