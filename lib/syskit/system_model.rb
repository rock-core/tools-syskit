module Orocos
    module RobyPlugin
        class SystemModel
            include CompositionModel

            attribute(:configuration) { Hash.new }

            def initialize
                @system = self
            end

            def has_interface?(name)
                Orocos::RobyPlugin::Interfaces.const_defined?(name.camelcase(true))
            end
            def register_interface(model)
                Orocos::RobyPlugin::Interfaces.const_set(model.name.camelcase(true), model)
            end

            def has_device_driver?(name)
                Orocos::RobyPlugin::DeviceDrivers.const_defined?(name.camelcase(true))
            end
            def register_device_driver(model)
                Orocos::RobyPlugin::DeviceDrivers.const_set(model.name.camelcase(true), model)
            end
            def has_composition?(name)
                Orocos::RobyPlugin::Compositions.const_defined?(name.camelcase(true))
            end
            def register_composition(model)
                Orocos::RobyPlugin::Compositions.const_set(model.name.camelcase(true), model)
            end

            def data_source_type(name, options = Hash.new, &block)
                options = Kernel.validate_options options,
                    :child_of => DataSource,
                    :interface    => nil

                const_name = name.camelcase(true)
                if has_interface?(name)
                    raise ArgumentError, "there is already a data source named #{name}"
                end

                parent_model = options[:child_of]
                if parent_model.respond_to?(:to_str)
                    parent_model = Orocos::RobyPlugin::Interfaces.const_get(parent_model.camelcase(true))
                end
                model = parent_model.new_submodel(name, :interface => options[:interface])
                if block_given?
                    model.interface(&block)
                end

                register_interface(model)
                model.instance_variable_set :@name, name
                model
            end

            def device_type(name, options = Hash.new)
                options, device_options = Kernel.filter_options options,
                    :provides => nil, :interface => nil

                const_name = name.camelcase(true)
                if has_device_driver?(name)
                    raise ArgumentError, "there is already a device type #{name}"
                end

                device_model = DeviceDriver.new_submodel(name)

                if provides = options[:provides]
                    if provides.respond_to?(:to_str)
                        provides = Orocos::RobyPlugin::Interfaces.const_get(provides.camelcase(true))
                    end
                    device_model.include provides
                elsif options[:provides].nil?
                    begin
                        data_source = Orocos::RobyPlugin::Interfaces.const_get(const_name)
                    rescue NameError
                        data_source = self.data_source_type(name, :interface => options[:interface])
                    end
                    device_model.include data_source
                end

                register_device_driver(device_model)
                device_model
            end

            def bus_type(name, options  = Hash.new)
                name = name.to_str

                if has_device_driver?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBusDriver.new_submodel(name, options)
                register_device_driver(model)
            end

            def subsystem(name, &block)
                name = name.to_s
                if has_composition?(name)
                    raise ArgumentError, "there is already a composition named '#{name}'"
                end

                new_model = Composition.new_submodel(name, self)
                new_model.instance_eval(&block)
                register_composition(new_model)
                new_model
            end

            def configure(task_model, &block)
                task = get(task_model)
                if task.configure_block
                    raise SpecError, "#{task_model} already has a configure block"
                end
                task.configure_block = block
                self
            end

            def pretty_print(pp)
                inheritance = Hash.new { |h, k| h[k] = Set.new }
                inheritance["Orocos::Spec::Subsystem"] << "Orocos::Spec::Composition"

                pp.text "Subsystems"
                pp.nest(2) do
                    pp.breakable
                    subsystems.sort_by { |name, sys| name }.
                        each do |name, sys|
                        inheritance[sys.superclass.name] << sys.name
                        pp.text "#{name}: "
                        pp.nest(2) do
                            pp.breakable
                            sys.pretty_print(pp)
                        end
                        pp.breakable
                        end
                end

                pp.breakable
                pp.text "Models"
                queue = [[0, "Orocos::Spec::Subsystem"]]

                while !queue.empty?
                    indentation, model = queue.pop
                    pp.breakable
                    pp.text "#{" " * indentation}#{model}"

                    children = inheritance[model].
                    sort.reverse.
                    map { |m| [indentation + 2, m] }
                    queue.concat children
                end
            end

            #--
            # Note: this method HAS TO BE the last in the file
            def load(file)
                load_dsl_file(file, binding, true, Exception)
                self
            end
        end
    end
end

