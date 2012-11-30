module Syskit
    class Port
        # Models::Port the port model
        attr_reader :model
        # [Component] The component model this port is part of
        attr_reader :component

        def initialize(model, component)
            @model, @component = model, component
        end

        def to_orocos_port
            model.to_orocos_port(component)
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



