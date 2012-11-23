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

            # Registers a global exclusion for a class of ports, to be ignored
            # for all autoconnections
            #
            # Any of the arguments can be nil, in which case this criteria will
            # be ignored.
            #
            # @param [Class] the specific port class, usually Orocos::Spec::InputPort or Orocos::Spec::OutputPort
            # @param [String] the port name
            # @param [String] the type name of the port, as a string
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

