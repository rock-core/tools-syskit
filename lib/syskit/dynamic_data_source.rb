# frozen_string_literal: true

module Syskit
    # Resolve and re-resolve ports in the system and read from them
    #
    # Dynamic port resolvers allow to specify ports (or fields of these ports) of
    # interest. They then implement the machinery necessary to dynamically resolve
    # these ports and to provide a read interface from them.
    #
    # The goal of these ports is to provide a service-oriented view of the data
    # sources in the plan, for instance for the purpose of a UI or monitoring.
    # Using dynamic port resolvers, one may tag specific compositions or components
    # with services that are then used to 'find' the appropriate source at any
    # given state, in a way that's orthogonal from the data flow.
    class DynamicDataSource
        # The resolver's model
        #
        # @return [Models::DynamicDataSource]
        attr_reader :model

        def initialize(model, resolver: Models::DynamicDataSource::NullResolver.new)
            @model = model
            @resolver = resolver
            @reader = nil
        end

        # Returns whether a port matching this resolver has been found
        def valid?
            @reader
        end

        # Returns whether a port matching this resolver has been found
        def connected?
            @reader&.connected?
        end

        # Read data, either already read or new
        #
        # @return [nil,Typelib::Type] nil if there is has never been any data, or if
        #    there are no underlying port. A data sample otherwise.
        def read
            return unless (sample = @reader&.read)

            @resolver.__resolve(sample)
        end

        # Read new data
        #
        # @return [nil,Typelib::Type] nil if there is no new data or if there are
        #    no underlying port. A data sample otherwise.
        def read_new
            return unless (sample = @reader&.read_new)

            @resolver.__resolve(sample)
        end

        # Disconnect the source forcefully
        def disconnect
            @reader&.disconnect
            @reader = nil
        end

        class FromMatcher < DynamicDataSource
            def initialize(
                plan, model, resolver: Models::DynamicDataSource::NullResolver.new
            )
                super(model, resolver: resolver)
                @plan = plan
                @last_provider_task = nil
            end

            def disconnect
                super
                @last_port = nil
            end

            def update
                port = @model.port_model.each_in_plan(@plan).first
                port = port&.to_actual_port
                return @last_port if @last_port == port

                @reader&.disconnect
                @reader = nil

                return false unless port

                @reader = port.reader
                @last_port = port
                true
            end
        end

        # Provider interface for a static port
        class FromPort < DynamicDataSource
            def initialize(
                port, model, resolver: Models::DynamicDataSource::NullResolver.new
            )
                super(model, resolver: resolver)

                @port = port
                @reader = port.reader
            end

            def update
                @reader = nil unless @reader.port.component.plan
                @reader
            end
        end
    end
end
