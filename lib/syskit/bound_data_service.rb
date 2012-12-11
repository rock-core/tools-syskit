module Syskit
        # Representation of a data service as provided by an actual component
        #
        # It is usually created from a Models::BoundDataService instance using
        # Models::BoundDataService#bind(component)
        class BoundDataService
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

            def short_name
                "#{component}:#{provided_service_model.name}"
            end

	    def each_fullfilled_model(&block)
		model.each_fullfilled_model(&block)
	    end

            def fullfills?(*args)
                model.fullfills?(*args)
            end

            def find_input_port(port_name)
                if mapped_name = model.port_mappings_for_task[port_name.to_s]
                    component.find_input_port(mapped_name)
                end
            end

            def find_output_port(port_name)
                if mapped_name = model.port_mappings_for_task[port_name.to_s]
                    component.find_output_port(mapped_name)
                end
            end

            def data_writer(*names)
                component.data_writer(port_mappings_for_task[names.first], *names[1..-1])
            end

            def data_reader(*names)
                component.data_reader(port_mappings_for_task[names.first], *names[1..-1])
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

            def connect_ports(sink, mappings)
                mapped = Hash.new
                mappings.each do |(source_port, sink_port), policy|
                    mapped_source_name = model.port_mappings_for_task[source_port]
                    if !mapped_source_name
                        raise ArgumentError, "cannot find port #{source_port} on #{self}"
                    end
                    mapped[[mapped_source_name, sink_port]] = policy
                end
                component.connect_ports(sink, mapped)
            end
        end
end

