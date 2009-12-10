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
                    :type => self.class, :interface => nil

                model = options[:type].new
                model.include self
                model.extend  self::ClassExtension
                if options[:interface]
                    iface_spec = Roby.app.get_orocos_task_model(options[:interface]).orogen_spec
                    model.instance_variable_set(:@stereotypical_component, iface_spec)
                end
                model.name = name.to_str
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

            attr_reader :stereotypical_component

            # Returns the most generic task model that implements +self+. If
            # more than one task model is found, raises Ambiguous
            def task_model
                if @task_model
                    return @task_model
                end

                @task_model = Class.new(TaskContext) do
                    class << self
                        attr_accessor :name
                    end
                end
                @task_model.instance_variable_set(:@orogen_spec, stereotypical_component)
                @task_model.abstract
                @task_model.name = "#{name}DataSourceTask"
                @task_model.extend Model
                @task_model.data_source name, :model => self
                @task_model
            end

            def port(name)
                name = name.to_str
                stereotypical_component.each_port.find { |p| p.name == name }
            end

            def each_output(&block)
                stereotypical_component.each_output_port(&block)
            end
            def each_input(&block)
                stereotypical_component.each_input_port(&block)
            end

            def instanciate(*args, &block)
                task_model.instanciate(*args, &block)
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

            module ClassExtension
                def to_s # :nodoc:
                    "#<DeviceDriver: #{name}>"
                end

                def task_model
                    model = super
                    model.name = "#{name}DeviceDriverTask"
                    model
                end
            end
            extend ClassExtension
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


