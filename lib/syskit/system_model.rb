module Syskit
        # Access to all the available models
        #
        # The SystemModel instance is an access point to all the models that are
        # available to the deployment engine (services, compositions, ...) and
        # allows to define them as well.
        class SystemModel
            extend Logger::Forward
            extend Logger::Hierarchy

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

            def initialize
                @system_model = self
                @proxy_task_models = Hash.new

                @export = true
                @data_service_models = Hash.new
                @device_models = Hash.new
                @composition_models = Hash.new
                @ignored_ports_for_autoconnection = Array.new
            end

            attr_predicate :export?, true
            attr_reader :data_service_models
            attr_reader :device_models
            attr_reader :composition_models
            # The set of criteria to match ports that should be ignored during
            # autoconnection
            attr_reader :ignored_ports_for_autoconnection

            def has_data_service?(name)
                if data_service_models.has_key?(name)
                    true
                elsif data_service_models.has_key?(name.camelcase(:upper))
                    raise "trying to access data service models by their non-Roby name (i.e. #{name} instead of #{name.camelcase(:upper)}"
                end
            end

            def has_device?(name)
                if device_models.has_key?(name)
                    true
                elsif device_models.has_key?(name.camelcase(:upper))
                    raise "trying to access data service models by their non-Roby name (i.e. #{name} instead of #{name.camelcase(:upper)}"
                end
            end

            def has_composition?(name)
                if composition_models.has_key?(name)
                    true
                elsif composition_models.has_key?(name.camelcase(:upper))
                    raise "trying to access data service models by their non-Roby name (i.e. #{name} instead of #{name.camelcase(:upper)}"
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
                    Syskit::DataServices.const_set(const_name, model)
                end
            end

            def register_device(model)
                const_name = model.constant_name
                device_models[const_name] = model
                if export?
                    Syskit::Devices.const_set(const_name, model)
                end
            end

            # Add a new composition model
            def register_composition(model)
                const_name = model.constant_name
                composition_models[const_name] = model
                if export?
                    Syskit::Compositions.const_set(const_name, model)
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

            def each_deployment_model(&block)
                Roby.app.orocos_deployments.each_value(&block)
            end

            def each_task_model(&block)
                Roby.app.orocos_tasks.each_value(&block)
            end

            def each_model(&block)
                if !block_given?
                    return enum_for(:each_model)
                end
                each_data_service(&block)
                each_device(&block)
                each_composition(&block)
                each_deployment_model(&block)
                each_task_model(&block)
            end

            # Load the types defined in the specified oroGen projects
            def import_types_from(*names)
                Roby.app.main_orogen_project.import_types_from(*names)
            end

            # Create an abstract task model used to proxy the provided set of
            # services in a plan
            def proxy_task_model(models)
                models = models.to_set
                if model = @proxy_task_models[models]
                    return model
                else
                    @proxy_task_models[models] = DataServiceModel.proxy_task_model(models)
                end
            end

            # Registers a global exclusion for a class of ports, to be ignored
            # for all autoconnections
            #
            # Any of the arguments can be nil, in which case this criteria will
            # be ignored.
            #
            # @arg [Class] the specific port class, usually Orocos::Spec::InputPort or Orocos::Spec::OutputPort
            # @arg [String] the port name
            # @arg [String] the type name of the port, as a string
            #
            # It is usually used by plugins that manage certain ports
            def ignore_port_for_autoconnection(port_type, port_name, port_type_name)
                ignored_ports_for_autoconnection << [port_type, port_name, port_type_name]
            end

            # Returns true if a global exclusion rule matches +port+
            #
            # See #ignored_ports_for_autoconnection
            def ignored_for_autoconnection?(port)
                ignored_ports_for_autoconnection.any? do |port_klass, port_name, port_type_name|
                    (!port_klass || port.kind_of?(port_klass)) &&
                    (!port_name || port.name == port_name) &&
                    (!port_type_name || port.type_name == port_type_name)
                end
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
                    orogen = Orocos.master_project.using_task_library(n)
                    if !Roby.app.loaded_orogen_project?(n)
                        # The project was already loaded on
                        # Orocos.master_project before Roby kicked in. Just load
                        # the Roby part
                        Roby.app.import_orogen_project(n, orogen)
                    end
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
                    :config_type => nil

                if has_data_service?(name)
                    raise ArgumentError, "there is already a data service type named #{name}"
                end

                model = DataService.new_submodel("Syskit::DataServices::#{name}",
                        :system_model => self,
                        :config_type => options[:config_type], &block)

                register_data_service(model)
                model
            end

            # Creates a new device model
            #
            # The returned value is an instance of DeviceModel in which
            # Device has been included.
            #
            def device_type(name, options = Hash.new, &block)
                name = Model.validate_model_name("Devices", name)
                if has_device?(name)
                    raise ArgumentError, "there is already a device type #{name}"
                end

                model = Device.new_submodel("Syskit::Devices::#{name}", options.merge(:system_model => self), &block)
                register_device(model)
                model
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
                if has_device?(name)
                    raise ArgumentError, "there is already a device driver called #{name}"
                end

                model = ComBus.new_submodel("Syskit::Devices::#{name}", options.merge(:system_model => self), &block)
                register_device(model)
                model
            end

            # Creates a new task context model in this system model
            def task_context(name = nil, options = Hash.new, &block)
                if name.kind_of?(Hash)
                    name, options = nil, name
                end

                options = Kernel.validate_options options,
                    :child_of => Syskit::TaskContext

                klass = Class.new(options[:child_of])
                klass.instance_variable_set :@system_model, self
                if name
                    klass.orogen_spec  = Syskit.create_orogen_interface(name)
                end

                if name
                    namespace, basename = name.split '::'
                    if !basename
                        namespace, basename = nil, namespace
                    end

                    namespace =
                        if namespace
                            Syskit.orogen_project_module(namespace)
                        else
                            Syskit
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
                    new_model.with_module(*Syskit.constant_search_path, &block)
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
                inheritance["Syskit::Component"] << "Syskit::Composition"

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
                queue = [[0, "Syskit::Component"]]

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

            # Returns a graphviz file that can be processed by 'dot', which
            # represents all the models defined in this SystemModel instance.
            def to_dot
                io = []
                io << "digraph {\n"
                io << "  node [shape=record,height=.1];\n"
                io << "  compound=true;\n"
                io << "  rankdir=LR;"

                io << "subgraph cluster_data_services {"
                io << "  label=\"DataServices\";"
                io << "  fontsize=18;"
                each_data_service do |m|
                    m.to_dot(io)
                end
                io << "}"

                models = each_composition.
                    find_all { |t| !t.is_specialization? }
                models.each do |m|
                    m.to_dot(io)
                end
                io << "}"
                io.join("\n")
            end
        end
end

