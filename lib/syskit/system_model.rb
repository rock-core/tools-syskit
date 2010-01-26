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
            def each_composition(&block)
                Orocos::RobyPlugin::Compositions.constants.
                    map { |name| Orocos::RobyPlugin::Compositions.const_get(name) }.
                    find_all { |model| model.kind_of?(Class) && model < Composition }.
                    each(&block)
            end

            def import_types_from(*names)
                Roby.app.main_orogen_project.import_types_from(*names)
            end
            def load_system_model(name)
                Roby.app.load_system_model(name)
            end
            def using_task_library(*names)
                names.each do |n|
                    Roby.app.load_orogen_project(n)
                end
            end

            def interface(*args, &block)
                data_source_type(*args, &block)
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

                device_model = DeviceDriver.new_submodel(name, :interface => false)

                if parents = options[:provides]
                    parents = [*parents].map do |parent|
                        if parent.respond_to?(:to_str)
                            Orocos::RobyPlugin::Interfaces.const_get(parent.camelcase(true))
                        else
                            parent
                        end
                    end
                    parents.delete_if do |parent|
                        parents.any? { |p| p < parent }
                    end

                    bad_models = parents.find_all { |p| !(p < DataSource) }
                    if !bad_models.empty?
                        raise ArgumentError, "#{bad_models.map(&:name).join(", ")} are not interface models"
                    end

                elsif options[:provides].nil?
                    begin
                        parents = [Orocos::RobyPlugin::Interfaces.const_get(const_name)]
                    rescue NameError
                        parents = [self.data_source_type(name, :interface => options[:interface])]
                    end
                end

                if parents
                    parents.each { |p| device_model.include(p) }

                    interfaces = parents.find_all { |p| p.interface }
                    child_spec = device_model.create_orogen_interface
                    if !interfaces.empty?
                        first_interface = interfaces.shift
                        child_spec.subclasses first_interface.interface.name
                        interfaces.each do |p|
                            child_spec.implements p.interface.name
                            child_spec.merge_ports_from(p.interface)
                        end
                    end
                    device_model.instance_variable_set :@orogen_spec, child_spec
                end

                register_device_driver(device_model)
                device_model
            end

            def com_bus_type(name, options  = Hash.new)
                name = name.to_str

                if has_device_driver?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBusDriver.new_submodel(name, options)
                register_device_driver(model)
            end

            def composition(name, options = Hash.new, &block)
                subsystem(name, options, &block)
            end

            def subsystem(name, options = Hash.new, &block)
                name = name.to_s
                if has_composition?(name)
                    raise ArgumentError, "there is already a composition named '#{name}'"
                end

                options = Kernel.validate_options options, :child_of => Composition

                new_model = options[:child_of].new_submodel(name, self)
                new_model.instance_eval(&block) if block_given?
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

