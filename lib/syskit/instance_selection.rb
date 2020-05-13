# frozen_string_literal: true

module Syskit
    # A representation of a selection matching a given requirement
    class InstanceSelection
        # The selected task, if one is specified explicitly
        #
        # @return [Syskit::Component]
        attr_reader :component
        # [InstanceRequirements] the required instance
        attr_reader :required
        # [InstanceRequirements] the selected instance. It can only refer to
        # a single component model. This model is available with
        # {#component_model}
        #
        # @see selected_model
        attr_reader :selected
        # [{Model<DataService> => Models::BoundDataService}] a mapping from
        # the services in {#required} to the services of {#component_model}.
        attr_reader :service_selection

        def initialize(component = nil, selected = InstanceRequirements.new([Component]), required = InstanceRequirements.new, mappings = {})
            @component = component

            selected = @selected = autoselect_service_if_needed(selected, required, mappings)
            required = @required = required.dup
            @service_selection =
                InstanceSelection.compute_service_selection(selected, required, mappings)
        end

        def initialize_copy(old)
            @component = old.component
            @selected = old.selected.dup
            @required = old.required.dup
            @service_selection = service_selection.dup
        end

        # Returns the simplest model representation for {selected}
        #
        # It mostly either returns {selected} or {selected}.model if
        # {InstanceRequirements#plain?} returns resp. false or true
        #
        # @return [BoundDataService,Model<Component>,InstanceRequirements]
        def selected_model
            selected.simplest_model_representation
        end

        def autoselect_service_if_needed(selected, required, mappings)
            return selected.dup if selected.service

            if required_srv = required.service
                if srv = selected.find_data_service(required_srv.name)
                    srv
                elsif m = mappings[required.service.model]
                    selected = selected.dup
                    selected.select_service(m)
                else
                    selected.find_data_service_from_type(required_srv.model)
                end

            elsif !required.component_model
                required_services = required.each_required_service_model.to_a
                if required_services.size == 1
                    required_srv = required_services.first
                    if m = mappings[required_srv]
                        selected = selected.dup
                        selected.select_service(m)
                    else
                        selected.find_data_service_from_type(required_srv)
                    end
                else selected.dup
                end

            else selected.dup
            end
        end

        # Returns the selected component model
        def component_model
            selected.base_model
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
        def self.compute_service_selection(selected, required, mappings)
            mappings = mappings.dup
            if selected.service
                # Save this selection explicitly
                mappings[selected.service.model] = selected.service
            end

            selected_component_model = selected.model.to_component_model
            required_component_model = required.component_model || Syskit::Component
            required_service_models = required.each_required_service_model.to_a

            mappings[required_component_model] =
                selected_component_model

            required_service_models.each do |required_m|
                if selected_m = mappings[required_m]
                    # Verify that it is of the right type
                    if !selected_component_model.fullfills?(selected_m.component_model)
                        raise ArgumentError, "#{selected_m} was explicitly selected for #{required_m}, but is not a service of the selected component model #{selected_component_model}"
                    elsif !selected_m.fullfills?(required_m)
                        raise ArgumentError, "#{selected_m} was explicitly selected for #{required_m}, but does not provide it"
                    end

                    mappings[required_m] = selected_m.attach(selected_component_model)
                else
                    selected_m = selected_component_model.find_data_service_from_type(required_m)
                    unless selected_m
                        raise ArgumentError, "selected model #{selected} does not provide required service #{required_m.short_name}"
                    end
                end

                mappings[required_m] = selected_m
            end
            mappings
        end

        # Compute the combined port mappings given the service selection in
        # {#service_selection}.
        #
        # @raise [AmbiguousPortMappings] if two services that were separate
        #   in {#required} used the same port name
        def port_mappings
            if @port_mappings then return @port_mappings end

            mappings = {}
            service_selection.each do |req_m, sel_m|
                mappings.merge!(sel_m.port_mappings_for(req_m)) do |req_name, sel_name1, sel_name2|
                    if sel_name1 != sel_name2
                        # need to find who has the same port ...
                        service_selection.each_key do |other_m|
                            if req_m.has_port?(req_name)
                                raise AmbiguousPortMappings.new(other_m, req_m, req_name)
                            end
                        end
                    else sel_name1
                    end
                end
            end
            @port_mappings = mappings
        end

        # If this selection does not yet have an associated task,
        # instanciate one
        def instanciate(plan, context = Syskit::DependencyInjectionContext.new, **options)
            if component
                # We have an explicitly selected component. We just need to
                # bind the bound data service if there is one
                component = plan[self.component]
                if selected_service = selected.service
                    selected_service.bind(component)
                else component
                end
            else
                selected.instanciate(plan, context, **options)
            end
        end

        def bind(task)
            selected.bind(task)
        end

        def each_fullfilled_model(&block)
            required.each_fullfilled_model(&block)
        end

        def fullfills?(set)
            selected.fullfills?(set)
        end

        def to_s
            "#<#{self.class}: #{required} selected=#{selected} service_selection=#{service_selection}>"
        end

        def pretty_print(pp)
            pp.text "Instance selection for "
            pp.nest(2) do
                pp.breakable
                pp.text "Component"
                if component
                    pp.nest(2) do
                        pp.breakable
                        component.pretty_print(pp)
                    end
                end
                pp.breakable
                pp.text "Required"
                pp.nest(2) do
                    pp.breakable
                    required.pretty_print(pp)
                end
                pp.breakable
                pp.text "Selected"
                pp.nest(2) do
                    pp.breakable
                    selected.pretty_print(pp)
                end
                pp.breakable
                pp.text "Services"
                unless service_selection.empty?
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
