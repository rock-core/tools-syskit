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
                in_port = in_port.to_component_port
                component.connect_ports(in_port.component, [out_port.name, in_port.name] => policy)
            else
                out_port.connect_to(in_port, policy)
            end
        end
    end

    class InputPort < Port
    end

    class OutputPort < Port
        def to_data_source
            DataSource.new(self)
        end

        # A data source for a port attached to a component
        class DataSource
            attr_reader :port
            attr_reader :reader

            def initialize(port)
                @port = port
                port.component.execute do
                    @reader = port.to_orocos_port.data_reader
                end
            end

            def read
                reader.read if reader
            end
        end
    end
end



