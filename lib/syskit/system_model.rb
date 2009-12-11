module Orocos
    module RobyPlugin
        class SystemModel
            include CompositionModel

            attribute(:interfaces)    { Hash.new }
            attribute(:data_source_types)  { Hash.new }
            attribute(:device_types)  { Hash.new }
            attribute(:subsystems)    { Hash.new }
            attribute(:configuration) { Hash.new }

            def initialize
                Roby.app.orocos_tasks.each do |name, model|
                    subsystems[name] = model
                end
                @system = self
            end

            def load_all_models
                subsystems['RTT::TaskContext'] = Orocos::Spec::TaskContext
                rtt_taskcontext = Orocos::Generation::Component.standard_tasks.
                    find { |task| task.name == "RTT::TaskContext" }
                Orocos::Spec::TaskContext.task_model = rtt_taskcontext

                Orocos.available_task_models.each do |name, task_lib|
                    next if subsystems[name]

                    task_lib   = Orocos::Generation.load_task_library(task_lib)
                    task_model = task_lib.find_task_context(name)
                    define_task_context_model(task_model)
                end
            end

            def data_source_type(name, options = Hash.new)
                options = Kernel.validate_options options,
                    :parent_model => DataSource,
                    :interface    => nil

                parent_model = options[:parent_model]

                if model = Roby.app.orocos_data_sources[name]
                    model
                else
                    if parent_model.respond_to?(:to_str)
                        if !(parent_model = Roby.app.orocos_data_sources[parent_model.to_str])
                            raise SpecError, "no data source named #{parent_model}"
                        end
                    end
                    model = Roby.app.orocos_data_sources[name.to_str] = parent_model.new_submodel(name, :interface => options[:interface])
                end
                data_source_types[name] = model
            end

            def device_type(name, options = Hash.new)
                options, device_options = Kernel.filter_options options, :provides => false, :interface => nil

                if !(device_model = Roby.app.orocos_devices[name])
                    device_model = Roby.app.orocos_devices[name.to_str] = DeviceDriver.new_submodel(name)
                end
                if options[:provides] != false
                    if options[:provides]
                        source = options[:provides]
                        if source.respond_to?(:to_str)
                            source = Roby.app.orocos_data_sources[source.to_str]
                            if !source
                                raise SpecError, "no source is named #{options[:provides]}"
                            end
                        end
                        device_model.include source
                    end
                else
                    if !(data_source = Roby.app.orocos_data_sources[name])
                        data_source = self.data_source_type(name, :interface => options[:interface])
                    end
                    device_model.include data_source
                end

                device_model
            end
            def bus_type(name, options  = Hash.new)
                name = name.to_str
                if !(device_model = Roby.app.orocos_devices[name])
                    Roby.app.orocos_devices[name] = ComBusDriver.new_submodel(name, options)
                end
            end

            def subsystem(name, &block)
                name = name.to_s
                if subsystems[name]
                    raise ArgumentError, "subsystem '#{name}' is already defined"
                elsif Roby.app.orocos_devices[name]
                    raise ArgumentError, "'#{name}' is already the name of a device type"
                end

                new_model = Composition.new_submodel(name, self)
                subsystems[name] = new_model
                Roby.app.orocos_compositions[name] = new_model
                Orocos::RobyPlugin::Compositions.const_set(name.camelcase(true), new_model)
                new_model.instance_eval(&block)
                new_model
            end

            def get(name)
                if subsystem = subsystems[name] 
                    subsystem
                elsif data_source_model = Roby.app.orocos_data_sources[name]
                    data_source_model
                elsif device_model = Roby.app.orocos_devices[name]
                    device_model
                else
                    raise ArgumentError, "no subsystem, task or device type matches '#{name}'"
                end
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

