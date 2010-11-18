module Orocos
    module RobyPlugin
        class SystemModel
            extend Logger::Forward
            extend Logger::Hierarchy

            include CompositionModel

            def initialize
                @system = self
                @composition_specializations = Hash.new do |h, k|
                    h[k] = Hash.new { |a, b| a[b] = Hash.new }
                end
            end

            if method(:const_defined?).arity == 1 # probably Ruby 1.8
            def has_data_service?(name)
                Orocos::RobyPlugin::DataServices.const_defined?(name.camelcase(:upper))
            end
            def has_data_source?(name)
                Orocos::RobyPlugin::DataSources.const_defined?(name.camelcase(:upper))
            end
            def has_composition?(name)
                Orocos::RobyPlugin::Compositions.const_defined?(name.camelcase(:upper))
            end
            else
            def has_data_service?(name)
                Orocos::RobyPlugin::DataServices.const_defined?(name.camelcase(:upper), false)
            end
            def has_data_source?(name)
                Orocos::RobyPlugin::DataSources.const_defined?(name.camelcase(:upper), false)
            end
            def has_composition?(name)
                Orocos::RobyPlugin::Compositions.const_defined?(name.camelcase(:upper), false)
            end
            end

            def data_source_model(name)
                Orocos::RobyPlugin::DataSources.const_get(name.camelcase(:upper))
            end

            def data_service_model(name)
                Orocos::RobyPlugin::DataServices.const_get(name.camelcase(:upper))
            end

            def register_data_service(model)
                Orocos::RobyPlugin::DataServices.const_set(model.name.camelcase(:upper), model)
            end

            def register_data_source(model)
                Orocos::RobyPlugin::DataSources.const_set(model.name.camelcase(:upper), model)
            end

            # Add a new composition model
            def register_composition(model)
                Orocos::RobyPlugin::Compositions.const_set(model.name.gsub(/.*::/, ''), model)
            end

            def each_data_service(&block)
                if !block_given?
                    return enum_for(:each_data_service)
                end

                Orocos::RobyPlugin::DataServices.constants.
                    map { |name| Orocos::RobyPlugin::DataServices.const_get(name) }.
                    find_all { |model| model.kind_of?(Module) && model < DataService }.
                    each do |model|
                        yield(model)
                    end
            end

            # Enumerate the composition models that are available
            def each_composition(&block)
                if !block_given?
                    return enum_for(:each_composition)
                end

                Orocos::RobyPlugin::Compositions.constants.
                    map { |name| Orocos::RobyPlugin::Compositions.const_get(name) }.
                    find_all { |model| model.kind_of?(Class) && model < Composition }.
                    each do |model|
                        yield(model)
                        model.each_specialization(&block)
                    end
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
            # System model files contain data service, data sources and
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

            # DEPRECATED. Use #data_service
            def data_service_type(*args, &block) # :nodoc:
                data_service(*args, &block)
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
            def data_service(name, options = Hash.new, &block)
                options = Kernel.validate_options options,
                    :child_of => nil,
                    :provides => nil,
                    :interface => nil,
                    :config_type => nil

                options[:provides] ||= (options[:child_of] || DataService)

                const_name = name.camelcase(:upper)
                if has_data_service?(name)
                    raise ArgumentError, "there is already a data source named #{name}"
                end

                parent_model = options[:provides]
                if parent_model.respond_to?(:to_str)
                    parent_model = data_service_model(parent_model)
                    if !parent_model
                        raise ArgumentError, "parent model #{options[:provides]} does not exist"
                    end
                end
                model = parent_model.new_submodel(name, :interface => options[:interface])
                if block_given?
                    model.interface(&block)
                end

                register_data_service(model)
                model.instance_variable_set :@name, name
                model.config_type = options[:config_type]
                model
            end

            # DEPRECATED. Use data_source instead
            def data_source_type(name, options = Hash.new)
                data_source(name, options)
            end

            # Create a new data source model
            #
            # The returned value is an instance of DataServiceModel in which
            # DataSource has been included.
            #
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
            def data_source(name, options = Hash.new)
                options, device_options = Kernel.filter_options options,
                    :provides => nil, :child_of => nil, :interface => nil

                if options[:provides].nil?
                    options[:provides] = options[:child_of]
                end

                if has_data_source?(name)
                    raise ArgumentError, "there is already a device type #{name}"
                end

                source_model = DataSource.new_submodel(name, :interface => false)

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
                    begin
                        parents = [data_service_model(name)]
                    rescue NameError
                        parents = [self.data_service_type(name, :interface => options[:interface])]
                    end
                end

                if parents
                    parents.each { |p| source_model.include(p) }

                    interfaces = parents.find_all { |p| p.interface }
                    child_spec = source_model.create_orogen_interface
                    if options[:interface]
                        child_spec.subclasses options[:interface].orogen_spec.name
                    end
                    RobyPlugin.merge_orogen_interfaces(child_spec, interfaces)
                    source_model.instance_variable_set :@orogen_spec, child_spec
                end

                register_data_source(source_model)
                source_model
            end

            # DEPRECATED use #com_bus
            def com_bus_type(name, options = Hash.new) # :nodoc:
                com_bus(name, options)
            end

            # Creates a new communication bus model
            #
            # It accepts the same arguments than data_source. In addition, the
            # 'message_type' option must be used to specify what data type is
            # used to represent the bus messages:
            #
            #   com_bus 'can', :message_type => '/can/Message'
            #
            # The returned value is an instance of DataServiceModel, in which
            # ComBusDriver is included.
            def com_bus(name, options  = Hash.new)
                name = name.to_str

                if has_data_source?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBusDriver.new_submodel(name, options)
                register_data_source(model)
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
                options[:child_of].specializations.each do |spec|
                    spec.specialized_children.each do |name, model|
                        spec.definition_blocks.each do |block|
                            new_model.specialize(name, model, &block)
                        end
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
                            superclass = composition_model.parent_model
                            inheritance[superclass.name] << composition_model.name
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
                search_path = [RobyPlugin,
                    RobyPlugin::DataServices,
                    RobyPlugin::DataSources,
                    RobyPlugin::Compositions]
                if Kernel.load_dsl_file(file, self, search_path, !Roby.app.filter_backtraces?)
                    RobyPlugin.info "loaded #{file}"
                end
                self
            end

            # Internal helper for to_dot
            def composition_to_dot(io, model) # :nodoc:
                id = model.object_id

                model.connections.each do |(source, sink), mappings|
                    mappings.each do |(source_port, sink_port), policy|
                        io << "C#{id}#{source}:#{source_port} -> C#{id}#{sink}:#{sink_port};"
                    end
                end

                io << "subgraph cluster_#{id} {"
                io << "  fontsize=18;"
                io << "  C#{id} [style=invisible];"
                label = [model.name.dup]
                provides = model.each_data_service.map do |name, type|
                    "#{name}:#{type.name}"
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

                    label = "{{"
                    task_label = child_model.map { |m| m.name }.join(',')
                    task_label = "#{child_name}[#{task_label}]"

                    inputs = child_model.map { |m| m.each_input.map(&:name) }.
                        inject(&:concat).to_set
                    if !inputs.empty?
                        label << inputs.map do |port_name|
                            "<#{port_name}> #{port_name}"
                        end.join("|")
                        label << "|"
                    end
                    label << "<main> #{task_label}"

                    outputs = child_model.map { |m| m.each_output.map(&:name) }.
                        inject(&:concat).to_set
                    if !outputs.empty?
                        label << "|"
                        label << outputs.map do |port_name|
                            "<#{port_name}> #{port_name}"
                        end.join("|")
                    end
                    label << "}}"

                    io << "  C#{id}#{child_name} [label=\"#{label}\",fontsize=15];"
                    #io << "  C#{id} -> C#{id}#{child_name}"
                end
                io << "}"

                if !model.specializations.empty?
                    model.specializations.each do |specialized_model|
                        specialized_id = specialized_model.composition.object_id
                        io << "C#{id} -> C#{specialized_id} [ltail=cluster_#{id} lhead=cluster_#{specialized_id} weight=2];"

                        composition_to_dot(io, specialized_model.composition)
                    end
                end
            end

            # Returns a graphviz file that can be processed by 'dot', which
            # represents all the models defined in this SystemModel instance.
            def to_dot
                io = []
                io << "digraph {\n"
                io << "  node [shape=record,height=.1];\n"
                io << "  compound=true;\n"
                io << "  rankdir=LR;"

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

