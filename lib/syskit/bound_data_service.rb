# frozen_string_literal: true

module Syskit
    # Representation of a data service as provided by an actual component
    #
    # It is usually created from a Models::BoundDataService instance using
    # Models::BoundDataService#bind(component), or simply by calling the
    # task's service access (i.e. the _srv helpers or {Component#find_data_service)
    #
    # The model-level bound data service corresponding to self is {#model}.
    # The data service model is therefore {#model}.{#model}. The component
    # instance this data service is bound to is {#component}.
    #
    # {#component}.{#model} is guaranteed to be {#model}.{#component}
    class BoundDataService
        include MetaRuby::DSLs::FindThroughMethodMissing
        include Syskit::PortAccess

        # @return [Component] The component instance we are bound to
        attr_reader :component
        # The data service model we are an instance of.
        #
        # self is basically model.bind(component)
        #
        # @return [Models::BoundDataService]
        # @see service_model
        attr_reader :model
        # The data service name
        #
        # @return [String]
        def name
            model.name
        end

        def hash
            [self.class, component, model].hash
        end

        def eql?(other)
            other.kind_of?(self.class) &&
                other.component == component &&
                other.model == model
        end

        def ==(other)
            eql?(other)
        end

        # Returns the data service model
        #
        # @see model
        def service_model
            model.model
        end

        def initialize(component, model)
            unless component.kind_of?(Component)
                raise "expected a component instance, got #{component}"
            end

            unless model.kind_of?(Models::BoundDataService)
                raise "expected a model of a bound data service, got #{model}"
            end

            @component = component
            @model = model
        end

        # (see Component#self_port_to_component_port)
        def self_port_to_component_port(port)
            component.find_port(model.port_mappings_for_task[port.name])
        end

        # Automatically computes connections from the output ports of self
        # to the given port or to the input ports of the given component
        #
        # (see Syskit.connect)
        def connect_to(port_or_component, policy = {})
            Syskit.connect(self, port_or_component, policy)
        end

        def short_name
            "#{component}:#{model.short_name}"
        end

        def each_slave_data_service
            component.model.each_slave_data_service(model) do |slave_m|
                yield(slave_m.bind(component))
            end
        end

        def has_data_service?(name)
            component.model.each_slave_data_service(model) do |slave_m|
                return true if slave_m.name == name
            end
            false
        end

        # Looks for a slave data service by name
        def find_data_service(name)
            component.model.each_slave_data_service(model) do |slave_m|
                return slave_m.bind(component) if slave_m.name == name
            end
            nil
        end

        def each_fullfilled_model(&block)
            model.each_fullfilled_model(&block)
        end

        def fullfills?(*args)
            model.fullfills?(*args)
        end

        def data_writer(*names)
            component.data_writer(
                model.port_mappings_for_task[names.first],
                *names[1..-1]
            )
        end

        def data_reader(*names)
            component.data_reader(
                model.port_mappings_for_task[names.first],
                *names[1..-1]
            )
        end

        def as_plan
            component
        end

        def to_task
            component
        end

        def as(service)
            result = dup
            result.instance_variable_set(:@model, model.as(service))
            result
        end

        def to_s
            "#<BoundDataService: #{component.name}.#{model.name}>"
        end

        def inspect
            to_s
        end

        # Generates the InstanceRequirements object that represents +self+
        # best
        #
        # @return [Syskit::InstanceRequirements]
        def to_instance_requirements
            req = component.to_instance_requirements
            req.select_service(model)
            req
        end

        def has_through_method_missing?(m)
            MetaRuby::DSLs.has_through_method_missing?(
                self, m,
                "_srv" => :has_data_service?
            ) || super
        end

        def find_through_method_missing(m, args)
            MetaRuby::DSLs.find_through_method_missing(
                self, m, args,
                "_srv" => :find_data_service
            ) || super
        end

        DRoby = Struct.new :component, :model do
            def proxy(peer)
                BoundDataService.new(
                    peer.local_object(component),
                    peer.local_object(model)
                )
            end
        end

        def droby_dump(peer)
            DRoby.new(peer.dump(component), peer.dump(model))
        end
    end
end
