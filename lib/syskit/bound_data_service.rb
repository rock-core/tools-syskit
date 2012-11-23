module Syskit
        # Representation of a data service as provided by an actual component
        #
        # It is usually created from a Models::BoundDataService instance using
        # Models::BoundDataService#bind(task)
        class BoundDataService
            # @deprecated
            #
            # [Models::BoundDataService] the data service we are an instance of
            attr_reader :provided_service_model

            # [Models::BoundDataService] the data service we are an instance of
            def bound_data_service_model
                provided_service_model
            end
            # [Component] The task instance we are bound to
            attr_reader :task
            # [Models::BoundDataService] the data service we are an instance of
            attr_reader :model

            def ==(other)
                other.kind_of?(self.class) &&
                    other.task == task &&
                    other.model == model
            end

            def initialize(task, provided_service_model)
                @task, @provided_service_model = task, provided_service_model
                @model = provided_service_model
                if !task.kind_of?(Component)
                    raise "expected a task instance, got #{task}"
                end
                if !provided_service_model.kind_of?(Models::BoundDataService)
                    raise "expected a provided service, got #{provided_service_model}"
                end
            end

            def short_name
                "#{task}:#{provided_service_model.name}"
            end

	    def each_fullfilled_model(&block)
		model.component_model.each_fullfilled_model(&block)
	    end

            def fullfills?(*args)
                model.fullfills?(*args)
            end

            def find_input_port(port_name)
                if mapped_name = model.port_mappings_for_task[port_name.to_s]
                    task.find_input_port(mapped_name)
                end
            end

            def find_output_port(port_name)
                if mapped_name = model.port_mappings_for_task[port_name.to_s]
                    task.find_output_port(mapped_name)
                end
            end

            def as_plan
                task
            end

            def to_component
                task
            end

            def as(service)
                result = self.dup
                result.instance_variable_set(:@model, model.as(service)) 
                result
            end

            def to_s
                "#<BoundDataService: #{task.name}.#{model.name}>"
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
                task.connect_ports(sink, mapped)
            end
        end
end

