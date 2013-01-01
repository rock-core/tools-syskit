module Syskit
        # A representation of a selection matching a given requirement
        class InstanceSelection
            # [InstanceRequirements] the required instance
            attr_reader :required
            # [InstanceRequirements] the selected instance. It can only refer to
            # a single component model. This model is available with
            # {#component_model}
            attr_reader :selected
            # [{Model<DataService> => Models::BoundDataService}] a mapping from
            # the services in {#required} to the services of {#component_model}.
            attr_reader :service_selection

            def initialize(selected = InstanceRequirements.new([Component]), required = InstanceRequirements.new, mappings = Hash.new)
                @selected = selected
                @required = required
                @service_selection =
                    InstanceSelection.compute_service_selection(Syskit.proxy_task_model_for(selected.base_models), required.base_models, mappings)
            end

            # Returns the selected component model
            def component_model
                selected.base_models.first
            end

            # Computes the service selection that will allow to replace a
            # placeholder representing the required models by the given
            # component model. The additional mappings are only used as hints.
            #
            # @param [Model<Component>] component_m the component model
            # @param [Array<Model<Component>,Model<DataService>>] required
            #   the set of models that are required
            # @param [{Model<DataService>=>Models::BoundDataService}] mappings a mapping
            #   from data service models to the corresponding selected model on
            #   the component model
            # @return [{Model<DataService>=>Models::BoundDataService}] the
            #   mapping from the data service models in required_models to the
            #   corresponding bound data services in component_m
            #
            # @raise [ArgumentError] if a service in mappings is either not a
            #   service of component_model, or does not fullfill the data service
            #   it is selected for
            # @raise (see Models::Component#find_data_service_from_type)
            def self.compute_service_selection(component_m, required, mappings)
                selection = Hash.new

                required.each do |required_m|
                    if required_m.kind_of?(Class) && (required_m <= Syskit::Component)
                        selected_m = required_m
                    elsif selected_m = mappings[required_m]
                        # Verify that it is of the right type
                        if !selected_m.fullfills?(component_m)
                            raise ArgumentError, "#{selected_m} was explicitly selected for #{required_m}, but is not a service of the selected component model #{component_m}"
                        elsif !selected_m.fullfills?(required_m)
                            raise ArgumentError, "#{selected_m} was explicitly selected for #{required_m}, but does not provide it"
                        end
                    else
                        selected_m = component_m.find_data_service_from_type(required_m)
                    end

                    if !selected_m
                        raise ArgumentError, "selected model #{component_m.short_name} does not provide required service #{required_m.short_name}"
                    end
                    selection[required_m] = selected_m
                end
                selection
            end

            # Compute the combined port mappings given the service selection in
            # {#service_selection}.
            #
            # @raise [AmbiguousPortMappings] if two services that were separate
            #   in {#required} used the same port name
            def port_mappings
                if @port_mappings then return @port_mappings end

                mappings = Hash.new
                service_selection.each do |req_m, sel_m|
                    mappings.merge!(sel_m.port_mappings_for(req_m)) do |req_name, sel_name1, sel_name2|
                        if sel_name1 != sel_name2
                            # need to find who has the same port ...
                            service_selection.each_key do |other_m|
                                if req_m.has_port?(req_name)
                                    raise AmbiguousPortMappings.new(other_m, req_m, req_name)
                                end
                            end
                        end
                    end
                end
                @port_mappings = mappings
            end

            # If this selection does not yet have an associated task,
            # instanciate one
            def instanciate(engine, context, options = Hash.new)
                selected.instanciate(engine, context, options)
            end

            def each_fullfilled_model(&block)
                required.each_fullfilled_model(&block)
            end

            def fullfills?(set)
                required.fullfills?(set)
            end

            def to_s
                "#<#{self.class}: #{required} selected=#{selected} service_selection=#{service_selection}>"
            end

            def pretty_print(pp)
                pp.text "Instance selection for "
                pp.nest(2) do
                    pp.breakable
                    required.pretty_print(pp)
                    pp.breakable
                    pp.text "Selected"
                    pp.nest(2) do
                        pp.breakable
                        selected.pretty_print(pp)
                    end
                    pp.breakable
                    pp.text "Service selection"
                    if !service_selection.empty?
                        pp.nest(2) do
                            pp.breakable
                            pp.seplist(service_selection) do |sel|
                                pp.text "#{sel[0].short_name} => #{sel[1].short_name}"
                            end
                        end
                    end
                end
            end
        end
end
