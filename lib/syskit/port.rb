module Syskit
    # Representation of a component port on a component instance.
    #
    # The sibling class Syskit::Models::Port represents a port on a component
    # model. For instance, an object of class Syskit::Models::Port could
    # be used to represent a port on a subclass of TaskContext while
    # Syskit::Port would represent it for an object of that subclass.
    class Port
        # The port model
        # @return [Models::Port]
        attr_reader :model
        # The component model this port is part of
        attr_reader :component
        # The port name
        def name; model.name end
        # The port type
        def type; model.type end

        def ==(other_port)
            other_port.class == self.class &&
                other_port.model == self.model &&
                other_port.component == self.component
        end

        def initialize(model, component)
            @model, @component = model, component
        end

        # Returns the port attached to a proper Component instance that
        # corresponds to self
        #
        # @raise [ArgumentError] if it is not possible (for instance, ports on
        #   InstanceRequirements are not associated with a component port)
        # @return [Port] the resolved port
        def to_component_port
            if !component.respond_to?(:self_port_to_component_port)
                raise ArgumentError, "cannot call #to_component_port on ports of #{component}"
            end
            component.self_port_to_component_port(self)
        end

        # Returns the orocos port attached that corresponds to self
        #
        # @raise [ArgumentError] if it is not possible (for instance, ports on
        #   InstanceRequirements are not associated with a component port)
        # @return [Orocos::Port] the resolved port
        def to_orocos_port
            component_port = to_component_port
            component_port.component.self_port_to_orocos_port(component_port)
        end

        # Connects this port to the other given port, using the given policy
        def connect_to(in_port, policy = Hash.new)
            out_port = self.to_component_port
            if out_port == self
                if in_port.respond_to?(:to_component_port)
                    in_port = in_port.to_component_port
                    component.connect_ports(in_port.component, [out_port.name, in_port.name] => policy)
                else
                    Syskit.connect self, in_port, policy
                end

            else
                out_port.connect_to(in_port, policy)
            end
        end
    end

    class InputPort < Port
        # Enumerates all ports connected to this one
        def each_connection
            port = to_component_port
            port.component.each_input_connection(port.name) do |out_task, out_port_name, in_port_name, policy|
                yield(out_task.find_output_port(out_port_name), policy)
            end
            self
        end

        # Enumerates all ports connected to this one
        def each_concrete_connection
            port = to_component_port
            port.component.each_concrete_input_connection(port.name) do |out_task, out_port_name, in_port_name, policy|
                yield(out_task.find_output_port(out_port_name), policy)
            end
            self
        end
    end

    class OutputPort < Port
        def to_data_source
            OutputReader.new(self)
        end

        def reader(policy = Hash.new)
            OutputReader.new(self, policy)
        end

        # Enumerates all ports connected to this one
        def each_connection
            port = to_component_port
            port.component.each_output_connection(port.name) do |_, in_port_name, in_task, policy|
                yield(in_task.find_input_port(in_port_name), policy)
            end
            self
        end

        # Enumerates all ports connected to this one
        def each_concrete_connection
            port = to_component_port
            port.component.each_concrete_output_connection(port.name) do |_, in_port_name, in_task, policy|
                yield(in_task.find_input_port(in_port_name), policy)
            end
            self
        end
    end

    # A data source for a port attached to a component
    class OutputReader
        # The port for which this is a reader
        # @return [Syskit::OutputPort]
        attr_reader :port
        # The connection policy
        attr_reader :policy
        # The actual data reader itself
        # @return [Orocos::OutputReader]
        attr_reader :reader

        def initialize(port, policy = Hash.new)
            @port = port.to_component_port
            @policy = policy
            @port.component.execute do |component|
                @port = component.find_port(@port.name)
                @reader = @port.to_orocos_port.reader(policy)
            end
        end

        def read
            reader.read if reader
        end
    end
end



