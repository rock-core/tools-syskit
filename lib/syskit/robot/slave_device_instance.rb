# frozen_string_literal: true

module Syskit
    module Robot
        # A SlaveDeviceInstance represents slave devices, i.e. data services
        # that are provided by other devices. For instance, a camera image from
        # a stereocamera device.
        class SlaveDeviceInstance < DeviceInstance
            # The MasterDeviceInstance that we depend on
            attr_reader :master_device
            # The actual service on master_device's task model
            attr_reader :service

            def each_fullfilled_model(&block)
                service.model.each_fullfilled_model(&block)
            end

            def robot
                master_device.robot
            end

            def task_model
                master_device.task_model
            end

            def device_model
                service.model
            end

            # The slave name. It is the same name than the corresponding service
            # on the task model
            def name
                service.name
            end

            def full_name
                "#{master_device.name}.#{name}"
            end

            # Defined to be consistent with task and data service models
            def short_name
                "#{name}[#{service.model.short_name}]"
            end

            def initialize(master_device, service)
                @master_device = master_device
                @service = service
            end

            def task
                master_device.task
            end

            def period(*args)
                if args.empty?
                    super || master_device.period
                else
                    super
                end
            end

            def sample_size(*args)
                if args.empty?
                    super || master_device.sample_size
                else
                    super
                end
            end

            def burst(*args)
                if args.empty?
                    super || master_device.burst
                else
                    super
                end
            end

            # Returns the InstanceRequirements object that can be used to
            # represent this device
            def to_instance_requirements
                req = master_device.to_instance_requirements
                req.select_service(service)
                req
            end

            def to_s
                "device(#{device_model.short_name}, :as => #{full_name}).#{name}_srv"
            end

            def ==(other)
                other.kind_of?(SlaveDeviceInstance) &&
                    other.master_device == master_device &&
                    other.name == name
            end
        end
    end
end
