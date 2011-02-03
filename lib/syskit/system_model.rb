module Orocos
    module RobyPlugin
        class SystemModel
            extend Logger::Forward
            extend Logger::Hierarchy

            # Safe port mapping merging implementation
            #
            # It verifies that there is no conflicting mappings, and if there
            # are, raises Ambiguous
            def self.merge_port_mappings(a, b)
                a.merge(b) do |source, target_a, target_b|
                    if target_a != target_b
                        raise Ambiguous, "merging conflicting port mappings: #{source} => #{target_a} and #{source} => #{target_b}"
                    end
                    target_a
                end
            end

            # Updates the port mappings in +result+ by applying +new_mappings+
            # on +old_mappings+
            #
            # +result+ and +old_mappings+ map service models to the
            # corresponding port mappings, of the form from => to
            #
            # +new_mappings+ is a new name mapping of the form from => to
            #
            # The method updates result by applying +new_mappings+ to the +to+
            # fields in +old_mappings+, saving the resulting mappins in +result+
            def self.update_port_mappings(result, new_mappings, old_mappings)
                old_mappings.each do |service, mappings|
                    updated_mappings = Hash.new
                    mappings.each do |from, to|
                        updated_mappings[from] = new_mappings[to] || to
                    end
                    result[service] =
                        SystemModel.merge_port_mappings(result[service] || Hash.new, updated_mappings)
                end
            end

            def self.log_array(level, first_header, header, array)
                first = true
                array.each do |line|
                    if first
                        send(level, "#{first_header}#{line}")
                        first = false
                    else
                        send(level, "#{header}#{line}")
                    end
                end
            end

            include CompositionModel

            def initialize
                @system_model = self
                @composition_specializations = Hash.new do |h, k|
                    h[k] = Hash.new { |a, b| a[b] = Hash.new }
                end

                @export = true
                @data_service_models = Hash.new
                @device_models = Hash.new
                @composition_models = Hash.new
            end

            attr_predicate :export?, true
            attr_reader :data_service_models
            attr_reader :device_models
            attr_reader :composition_models

            def has_data_service?(name)
                if data_service_models.has_key?(name)
                    true
                elsif data_service_models.has_key?(name.camelcase(:upper))
                    raise
                end
            end

            def has_device?(name)
                if device_models.has_key?(name)
                    true
                elsif device_models.has_key?(name.camelcase(:upper))
                    raise
                end
            end

            def has_composition?(name)
                if composition_models.has_key?(name)
                    true
                elsif composition_models.has_key?(name.camelcase(true))
                    raise
                end
            end

            def device_model(name)
                if !(m = device_models[name])
                    raise ArgumentError, "there is no device model called #{name}"
                end
                m
            end

            MODEL_QUERY_METHODS =
                { DataService => 'data_service_model',
                  Device => 'device_model' }

            def data_service_model(name)
                if !(m = data_service_models[name])
                    raise ArgumentError, "there is no data service model called #{name}"
                end
                m
            end

            def composition_model(name)
                if !(m = composition_models[name])
                    raise ArgumentError, "there is no composition model called #{name}"
                end
                m
            end

            def register_data_service(model)
                const_name = model.constant_name
                data_service_models[const_name] = model
                if export?
                    Orocos::RobyPlugin::DataServices.const_set(const_name, model)
                end
            end

            def register_device(model)
                const_name = model.constant_name
                device_models[const_name] = model
                if export?
                    Orocos::RobyPlugin::Devices.const_set(const_name, model)
                end
            end

            # Add a new composition model
            def register_composition(model)
                const_name = model.constant_name
                composition_models[const_name] = model
                if export?
                    Orocos::RobyPlugin::Compositions.const_set(const_name, model)
                end
            end

            def each_data_service(&block)
                data_service_models.each_value(&block)
            end

            def each_device(&block)
                device_models.each_value(&block)
            end

            def each_composition(&block)
                composition_models.each_value(&block)
            end

            def each_task_model(&block)
                Roby.app.orocos_tasks.each_value(&block)
            end

            # Load the types defined in the specified oroGen projects
            def import_types_from(*names)
                Roby.app.main_orogen_project.import_types_from(*names)
            end

            # Load a system model file
            #
            # System model files contain data service, devices and
            # composition definitions.
            def load_system_model(name)
                Roby.app.load_system_model(name)
            end

            # Load the specified oroGen project and register the task contexts
            # and deployments they contain.
            def using_task_library(*names)
                names.each do |n|
                    Roby.app.load_orogen_project(n)
                end
            end

            # If +name+ is a model object, returns it.
            #
            # If +name+ is a string, create a new model of type +expected_type+
            # using +options+
            #
            # +expected_type+ is supposed to be the model's class, i.e. one of
            # DataServiceModel, DeviceModel or ComBusModel
            def query_or_create_service_model(name, expected_type, options, &block)
                if name.respond_to?(:to_str)
                    case expected_type.base_module
                    when DeviceModel
                        device_type(name, options, &block)
                    when DataServiceModel
                        data_service_type(name, options, &block)
                    when ComBusModel
                        com_bus_type(name, options, &block)
                    else raise ArgumentError, "unexpected service type #{expected_type}"
                    end
                else
                    Model.validate_service_model(name, self, expected_type.base_module)
                end
            end

            # Creates a new data service model
            #
            # The returned value is an instance of DataServiceModel
            #
            # If a block is given, it is used to declare the service's
            # interface, i.e. the input and output ports that are needed on any
            # task that provides this source.
            #
            # Available options:
            #
            # provides::
            #   another data service that this service implements. This is used
            #   to specialize services (i.e. this data service is a child model
            #   of the given data service). It can be either a data service name
            #   or object.
            # interface::
            #   alternatively to giving a block, it is possible to provide an
            #   Orocos::Generation::TaskContext instance directly to define the
            #   required interface.
            # config_type::
            #   the type of the configuration data structures
            def data_service_type(name, options = Hash.new, &block)
                name = Model.validate_model_name("DataService", name)

                options = Kernel.validate_options options,
                    :child_of => nil,
                    :provides => nil,
                    :interface => nil,
                    :config_type => nil

                options[:provides] ||= (options[:child_of] || DataService)

                const_name = name.camelcase(:upper)
                if has_data_service?(name)
                    raise ArgumentError, "there is already a data service type named #{name}"
                end

                parent_model = options[:provides]
                if parent_model.respond_to?(:to_str)
                    parent_model = data_service_model(parent_model)
                    if !parent_model
                        raise ArgumentError, "parent model #{options[:provides]} does not exist"
                    end
                end
                model = parent_model.new_submodel("Orocos::RobyPlugin::DataServices::#{name}",
                        :system_model => self,
                        :interface => options[:interface],
                        :config_type => options[:config_type], &block)

                register_data_service(model)
                model
            end

            # Create a new data source model
            #
            # The returned value is an instance of DataServiceModel in which
            # DataSource has been included.
            #
            def device_type(name, options = Hash.new, &block)
                name = Model.validate_model_name("Devices", name)
            # The following options are available:
            #
            # provides::
            #   a data service this data source provides. If it is not set, a
            #   data service will either be created with the same name than the
            #   data source, or it will be reused if a service already exists
            #   with that name.
            # interface::
            #   an instance of Orocos::Generation::TaskContext that represents
            #   the data source interface.
            #
            # If both provides and interface are provided, the interface must
            # match the data service's interface.
                options, device_options = Kernel.filter_options options,
                    :provides => nil, :child_of => nil, :interface => nil

                if options[:provides].nil?
                    options[:provides] = options[:child_of]
                end

                if has_data_source?(name)
                    raise ArgumentError, "there is already a device type #{name}"
                end

                if parents = options[:provides]
                    parents = [*parents].map do |parent|
                        if parent.respond_to?(:to_str)
                            data_service_model(parent)
                        else
                            parent
                        end
                    end
                    parents.delete_if do |parent|
                        parents.any? { |p| p < parent }
                    end

                    bad_models = parents.find_all { |p| !(p < DataService) }
                    if !bad_models.empty?
                        raise ArgumentError, "#{bad_models.map(&:name).join(", ")} are not interface models"
                    end

                elsif options[:provides].nil?
                    if has_data_service?(name)
                        parents = [data_service_model(name)]
                    else
                        parents = [self.data_service_type(
                            name, :interface => options[:interface])]
                    end
                end

                # Find which of DataSource and ComBus should be our parent
                # ...
                parent_model, options =
                    if com_bus = parents.find { |m| m < ComBus }
                        [ComBus, { :message_type => com_bus.message_type,
                            :override_policy => com_bus.override_policy? }]
                    else [DataSource, {}]
                    end

                source_model = parent_model.
                    new_submodel(name, options.merge(:interface => false), &block)
                parents.each { |p| source_model.provides(p) }
                register_data_source(source_model)
                source_model
            end

            # Creates a new communication bus model
            #
            # It accepts the same arguments than device_type. In addition, the
            # 'message_type' option must be used to specify what data type is
            # used to represent the bus messages:
            #
            #   com_bus 'can', :message_type => '/can/Message'
            #
            # The returned value is an instance of DataServiceModel, in which
            # ComBus is included.
            def com_bus_type(name, options  = Hash.new, &block)
                name = Model.validate_model_name("Devices", name)
                if has_data_source?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBus.new_submodel(
                    name, options.merge(:system_model => self))
                register_data_source(model)
                model
            end

            # Creates a new task context model in this system model
            def task_context(name = nil, options = Hash.new, &block)
                if name.kind_of?(Hash)
                    name, options = nil, name
                end

                options = Kernel.validate_options options,
                    :child_of => Orocos::RobyPlugin::TaskContext

                klass = Class.new(options[:child_of])
                klass.instance_variable_set :@system_model, system_model

                if name
                    namespace, basename = name.split '::'
                    if !namespace
                        namespace, basename = nil, namespace
                    end

                    namespace =
                        if namespace
                            Orocos::RobyPlugin.orogen_project_module(namespace)
                        else
                            Orocos::RobyPlugin
                        end
                    klass.instance_variable_set :@name, "#{namespace.name}::#{basename.camelcase(:upper)}"
                    namespace.const_set(basename.camelcase(:upper), klass)
                end

                if block_given?
                    klass.class_eval(&block)
                end
                klass
            end

            # call-seq:
            #   composition('composition_name') do
            #     # composition definition statements
            #   end
            #
            # Create a new composition model with the given name and returns it.
            # If a block is given, it is evaluated in the context of the new
            # composition model, i.e. any method defined on CompositionModel is
            # available in it:
            #
            #   composition('composition_name') do
            #     provides MyService
            #     add XsensImu::Task
            #   end
            #
            # The returned value is a subclass of Composition
            def composition(name, options = Hash.new, &block)
                name = name.to_s
                options = Kernel.validate_options options,
                    :child_of => Composition, :register => true

                if options[:register] && has_composition?(name)
                    raise ArgumentError, "there is already a composition named '#{name}'"
                end

                new_model = options[:child_of].new_submodel(name, self)
                if block_given?
                    new_model.with_module(*RobyPlugin.constant_search_path, &block)
                end

                # Apply existing specializations of the parent model on the
                # child
                #
                # Note: we must NOT move that to #new_submodel as #new_submodel
                # is used to create specializations as well !
                options[:child_of].specializations.each_value do |spec|
                    spec.definition_blocks.each do |block|
                        new_model.specialize(spec.specialized_children, &block)
                    end
                end

                if options[:register]
                    register_composition(new_model)
                end
                new_model
            end

            def pretty_print(pp) # :nodoc:
                inheritance = Hash.new { |h, k| h[k] = Set.new }
                inheritance["Orocos::RobyPlugin::Component"] << "Orocos::RobyPlugin::Composition"

                pp.text "Compositions"; pp.breakable
                pp.text "------------"; pp.breakable
                pp.nest(2) do
                    pp.breakable
                    each_composition.sort_by(&:name).
                        each do |composition_model|
                            composition_model.parent_models.each do |superclass|
                                inheritance[superclass.name] << composition_model.name
                            end
                            composition_model.pretty_print(pp)
                            pp.breakable
                        end
                end

                pp.breakable
                pp.text "Models"; pp.breakable
                pp.text "------"; pp.breakable
                queue = [[0, "Orocos::RobyPlugin::Component"]]

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

            # Load the given DSL file into this SystemModel instance
            def load(file)
                if Kernel.load_dsl_file(file, self, RobyPlugin.constant_search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
                self
            end

            def dot_iolabel(name, inputs, outputs)
                label = "{{"
                if !inputs.empty?
                    label << inputs.sort.map do |port_name|
                            "<#{port_name}> #{port_name}"
                    end.join("|")
                    label << "|"
                end
                label << "<main> #{name}"

                if !outputs.empty?
                    label << "|"
                    label << outputs.sort.map do |port_name|
                            "<#{port_name}> #{port_name}"
                    end.join("|")
                end
                label << "}}"
            end

            def data_services_to_dot(io, models)
                io << "subgraph cluster_data_services {"
                io << "  label=\"DataServices\";"
                io << "  fontsize=18;"
                models.each do |m|
                    id = m.object_id.abs
                    inputs = m.orogen_spec.all_input_ports.map(&:name)
                    outputs = m.orogen_spec.all_output_ports.map(&:name)
                    label = dot_iolabel(m.constant_name, inputs, outputs)
                    io << "  C#{id} [label=\"#{label}\",fontsize=15];"

                    m.parent_models.each do |parent_m|
                        parent_id = parent_m.object_id.abs
                        (parent_m.each_input_port.to_a + parent_m.each_output_port.to_a).
                            each do |parent_p|
                                io << "  C#{parent_id}:#{parent_p.name} -> C#{id}:#{m.port_mappings_for(parent_m)[parent_p.name]};"
                            end

                    end
                end
                io << "}"
            end

            # Internal helper for to_dot
            def composition_to_dot(io, model) # :nodoc:
                id = model.object_id.abs

                model.connections.each do |(source, sink), mappings|
                    mappings.each do |(source_port, sink_port), policy|
                        io << "C#{id}#{source}:#{source_port} -> C#{id}#{sink}:#{sink_port};"
                    end
                end

                if !model.is_specialization?
                    specializations = model.each_specialization.to_a
                    model.specializations.each do |spec, specialized_model|
                        composition_to_dot(io, specialized_model)

                        specialized_model.parent_models.each do |parent_compositions|
                            parent_id = parent_compositions.object_id
                            specialized_id = specialized_model.object_id
                            io << "C#{parent_id} -> C#{specialized_id} [ltail=cluster_#{parent_id} lhead=cluster_#{specialized_id} weight=2];"
                        end
                    end
                end

                io << "subgraph cluster_#{id} {"
                io << "  fontsize=18;"
                io << "  C#{id} [style=invisible];"

                if !model.exported_inputs.empty? || !model.exported_outputs.empty?
                    inputs = model.exported_inputs.keys
                    outputs = model.exported_outputs.keys
                    label = dot_iolabel("Composition Interface", inputs, outputs)
                    io << "  Cinterface#{id} [label=\"#{label}\",color=blue,fontsize=15];"
                    
                    model.exported_outputs.each do |exported_name, port|
                        io << "C#{id}#{port.child.child_name}:#{port.port.name} -> Cinterface#{id}:#{exported_name} [style=dashed];"
                    end
                    model.exported_inputs.each do |exported_name, port|
                        io << "Cinterface#{id}:#{exported_name} -> C#{id}#{port.child.child_name}:#{port.port.name} [style=dashed];"
                    end
                end
                label = [model.short_name.dup]
                provides = model.each_data_service.map do |name, type|
                    "#{name}:#{type.model.short_name}"
                end
                if model.abstract?
                    label << "Abstract"
                end
                if !provides.empty?
                    label << "Provides:"
                    label.concat(provides)
                end
                io << "  label=\"#{label.join("\\n")}\";"
                # io << "  label=\"#{model.name}\";"
                # io << "  C#{id} [style=invisible];"
                model.each_child do |child_name, child_definition|
                    child_model = child_definition.models

                    task_label = child_model.map(&:short_name).join(',')
                    task_label = "#{child_name}[#{task_label}]"
                    inputs = child_model.map { |m| m.each_input_port.map(&:name) }.
                        inject(&:concat).to_a
                    outputs = child_model.map { |m| m.each_output_port.map(&:name) }.
                        inject(&:concat).to_a
                    label = dot_iolabel(task_label, inputs, outputs)

                    if child_model.any? { |m| !(m <= Component) || m.abstract? }
                        color = ", color=\"red\""
                    end
                    io << "  C#{id}#{child_name} [label=\"#{label}\"#{color},fontsize=15];"
                end
                io << "}"
            end

            # Returns a graphviz file that can be processed by 'dot', which
            # represents all the models defined in this SystemModel instance.
            def to_dot
                io = []
                io << "digraph {\n"
                io << "  node [shape=record,height=.1];\n"
                io << "  compound=true;\n"
                io << "  rankdir=LR;"

                data_services_to_dot(io, each_data_service)

                models = each_composition.
                    find_all { |t| !t.is_specialization? }
                models.each do |m|
                    composition_to_dot(io, m)
                end
                io << "}"
                io.join("\n")
            end

            # Caches the result of #compare_composition_child to speed up the
            # instanciation process
            attr_reader :composition_specializations

            # Computes if the child called "child_name" is specialized in
            # +test_model+, compared to the definition in +base_model+.
            #
            # If both compositions have a child called child_name, then returns
            # 1 if the declared model is specialized in test_model, 0 if they
            # are equivalent and false in all other cases.
            #
            # If +test_model+ has +child_name+ but +base_model+ has not, returns
            # 1
            #
            # If +base_model+ has +child_name+ but not +test_model+, returns
            # false
            #
            # If neither have a child called +child_name+, returns 0
            def compare_composition_child(child_name, base_model, test_model)
                cache = composition_specializations[child_name][base_model]

                if cache.has_key?(test_model)
                    return cache[test_model]
                end

                base_child = base_model.find_child(child_name)
                test_child = test_model.find_child(child_name)
                if !base_child && !test_child
                    return cache[test_model] = 0
                elsif !base_child
                    return cache[test_model] = 1
                elsif !test_child
                    return cache[test_model] = false
                end

                base_child = base_child.models
                test_child = test_child.models

                flag = Composition.compare_model_sets(base_child, test_child)
                cache[test_model] = flag
                if flag == 0
                    cache[test_model] = 0
                elsif flag == 1
                    composition_specializations[child_name][test_model][base_model] = false
                end
                flag
            end
        end
    end
end

