# frozen_string_literal: true

module Syskit
    # @api private
    #
    # Base implementation of the creation of models that represent an arbitrary
    # mix of a task model and a set of data services.
    #
    # Its most common usage it to represent a single data service (which is seen
    # as a {Component} model with an extra data service). It can also be used to
    # represent a taskcontext model that should have an extra data service at
    # dependency-injection time because of e.g. dynamic service instantiation.
    module Placeholder
        def placeholder?
            true
        end

        def proxied_data_service_models
            model.proxied_data_service_models
        end

        def provided_models
            [model.proxied_component_model, model.proxied_data_service_models]
        end

        # @api private
        #
        # Create a port mapping hash to replace self by object
        #
        # @return [{String=>String}]
        # @raise AmbiguousPortOnCompositeModel if two of the proxied services have
        #   ports with the same name. We can't port-map in this case.
        def find_replacement_port_mappings(object)
            provided_models.flatten.inject({}) do |mappings, m|
                mappings.merge(object.model.port_mappings_for(m)) do |k, _|
                    raise AmbiguousPortOnCompositeModel,
                          "#{self}'s #{k} port is ambiguous, cannot port-map to #{object}"
                end
            end
        end

        # @api private
        #
        # Hook into the replacement computations to apply port mappings from services
        # to tasks
        def compute_task_replacement_operation(object, filter)
            mapping = find_replacement_port_mappings(object)
            added, removed = super
            [map_replacement_ports(object, added, mapping), removed]
        end

        # @api private
        #
        # Hook into the replacement computations to apply port mappings from services
        # to tasks
        def compute_subplan_replacement_operation(object, filter)
            mapping = find_replacement_port_mappings(object)
            added, removed = super
            [map_replacement_ports(object, added, mapping), removed]
        end

        # @api private
        #
        # Transform the 'added' replacement operations to apply port mappings
        def map_replacement_ports(object, added, mapping)
            added.map do |op|
                next(op) unless op[0].kind_of?(Syskit::Flows::DataFlow)

                g, source, sink, connections = *op
                connections =
                    if source == object
                        connections.transform_keys do |source_port, sink_port|
                            [mapping.fetch(source_port), sink_port]
                        end
                    elsif sink == object
                        connections.transform_keys do |source_port, sink_port|
                            [source_port, mapping.fetch(sink_port)]
                        end
                    else
                        raise
                    end

                [g, source, sink, connections]
            end
        end
    end
end
