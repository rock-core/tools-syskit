module Orocos
    module RobyPlugin
        # Base type for data source models (DataSource, DeviceDriver,
        # ComBusDriver). Methods defined in this class are available on said
        # models (for instance DeviceDriver.new_submodel)
        class DataSourceModel < Roby::TaskModelTag
            # The name of the model
            attr_accessor :name

            # Creates a new DataSourceModel that is a submodel of +self+
            def new_submodel(name, options = Hash.new)
                options = Kernel.validate_options options,
                    :type => self.class

                model = options[:type].new
                model.include self
                model::ClassExtension.include self::ClassExtension
                model.name    = name.to_str
                model
            end

            # Helper method to select a given data source model in 
            def self.apply_selection(task, type, name, model, arguments) # :nodoc:
                if model
                    task.include model
                    arguments.each do |key, value|
                        task.send("#{key}=", value)
                    end
                    model
                else
                    raise ArgumentError, "there is no #{type} type #{name}"
                end
                model
            end

            # Returns the most generic task model that implements +self+. If
            # more than one task model is found, raises Ambiguous
            def task_model
                if @task_model
                    return @task_model
                end

                # Get all task models that implement this device
                tasks = Roby.app.orocos_tasks.
                    find_all { |_, t| t.fullfills?(self) }.
                    map { |_, t| t }

                # Now, get the most abstract ones
                tasks.delete_if do |model|
                    tasks.any? { |t| model < t }
                end

                if tasks.size > 1
                    raise Ambiguous, "#{tasks.map(&:name).join(", ")} can all handle '#{name}', please select one explicitely with the 'using' statement"
                elsif tasks.empty?
                    raise SpecError, "no task can handle the device '#{name}'"
                end
                @task_model = tasks.first
            end
        end

        DataSource   = DataSourceModel.new
        DeviceDriver = DataSourceModel.new
        ComBusDriver = DataSourceModel.new

        module DataSource
            def self.to_s # :nodoc:
                "#<DataSource: #{name}>"
            end
        end

        # Module that represents the device drivers in the task models. It
        # defines the methods that are available on task instances. For
        # methods that are available at the task model level, see
        # DeviceDriver::ClassExtension
        module DeviceDriver
            argument "com_bus"
            argument "bus_name"

            def self.to_s # :nodoc:
                "#<DeviceDriver: #{name}>"
            end

            def device_name=(new_value)
                self.subdevices = self.class.subdevices.
                    keys.map { |subname| "#{new_value}.#{subname}" }
                arguments[:device_name] = new_value
            end

        end

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBusDriver
            # Communication busses are also device drivers
            include DeviceDriver

            def self.to_s # :nodoc:
                "#<ComBusDriver: #{name}>"
            end

            # Module that defines model-level methods for components that are
            # commmunication busses drivers. See ComBusDriver.
            module ClassExtension
                include DeviceDriver::ClassExtension

                # The name of the data type that represents data flowing through
                # this bus
                attr_accessor :message_type
            end

            # The output port name for the +bus_name+ device attached on this
            # bus
            def output_name_for(bus_name)
                bus_name
            end

            # The input port name for the +bus_name+ device attached on this bus
            def input_name_for(bus_name)
                "#{bus_name}w"
            end
        end
    end
end


