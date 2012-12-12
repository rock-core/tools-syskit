module Syskit
        # Representation of a data service as provided by an actual component
        #
        # It is usually created from a Models::BoundDataService instance using
        # Models::BoundDataService#bind(component)
        class BoundDataService
            include Syskit::PortAccess

            # @deprecated
            #
            # [Models::BoundDataService] the data service we are an instance of
            attr_reader :provided_service_model

            # [Models::BoundDataService] the data service we are an instance of
            def bound_data_service_model
                provided_service_model
            end
            # [Component] The component instance we are bound to
            attr_reader :component
            # [Models::BoundDataService] the data service we are an instance of
            attr_reader :model
            # The data service name
            # @return [String]
            def name
                model.name
            end

            def ==(other)
                other.kind_of?(self.class) &&
                    other.component == component &&
                    other.model == model
            end

            def initialize(component, provided_service_model)
                @component, @provided_service_model = component, provided_service_model
                @model = provided_service_model
                if !component.kind_of?(Component)
                    raise "expected a component instance, got #{component}"
                end
                if !provided_service_model.kind_of?(Models::BoundDataService)
                    raise "expected a provided service, got #{provided_service_model}"
                end
            end

            # (see Component#self_port_to_component_port)
            def self_port_to_component_port(port)
                return component.find_port(model.port_mappings_for_task[port.name])
            end

            # Automatically computes connections from the output ports of self
            # to the given port or to the input ports of the given component
            #
            # (see Syskit.connect)
            def connect_to(port_or_component)
                Syskit.connect(self, port_or_component)
            end

            def short_name
                "#{component}:#{provided_service_model.name}"
            end

            def each_slave_data_service(&block)
                component.model.each_slave_data_service(self.model) do |slave_m|
                    yield(slave_m.bind(component))
                end
            end

	    def each_fullfilled_model(&block)
		model.each_fullfilled_model(&block)
	    end

            def fullfills?(*args)
                model.fullfills?(*args)
            end

            def data_writer(*names)
                component.data_writer(model.port_mappings_for_task[names.first], *names[1..-1])
            end

            def data_reader(*names)
                component.data_reader(model.port_mappings_for_task[names.first], *names[1..-1])
            end

            def as_plan
                component
            end

            def to_component
                component
            end

            def as(service)
                result = self.dup
                result.instance_variable_set(:@model, model.as(service)) 
                result
            end

            def to_s
                "#<BoundDataService: #{component.name}.#{model.name}>"
            end
        end
end

