# frozen_string_literal: true

module Syskit
    module Models
        # Proxy class that gives access to a component under the cover of a
        # certain number of models (e.g. services, ...) to make it "look like"
        # one of these components
        #
        # It can be used on component instances and component models
        #
        # One rarely creates an instance of this object directly, but uses the #as()
        # acessor on component models
        class FacetedAccess < InstanceSelection
            # The object to which we are giving a faceted access
            attr_reader :object
            # @return [{String=>[Port]}] the ports on {required} that provide the
            #   named port
            attr_reader :ports_on_required
            # @return [{String=>Port}] mapping of ports in {required} to ports in
            #   {object}
            attr_reader :port_mappings

            def initialize(object, required, mappings = {})
                super(nil, object.to_instance_requirements, required.to_instance_requirements, mappings)
                @object = object
                @ports_on_required = {}
                @port_mappings = {}
            end

            def find_ports_on_required(name)
                result = []
                required.each_required_model do |m|
                    if p = m.find_port(name)
                        result << p
                    end
                end
                result
            end

            def find_data_service(name)
                # The name of data services cannot change between the facet and the
                # real object, just return the one from the real object
                object.find_data_service(name)
            end

            def find_data_service_from_type(type)
                srv = required.find_data_service_from_type(type)
                if !required.each_required_model.to_a.include?(srv.model)
                    find_data_service(srv.name)
                else
                    srv
                end
            end

            # Find all possible port mappings for the given port name to {#object}
            #
            # @param [String] name the port name on {#required}
            # @return [Set<Port>] the set of ports on {#object} that are mapped
            #   from {#required}
            def find_all_port_mappings_for(name)
                candidates = Set.new
                ports_on_required[name] ||= find_ports_on_required(name)
                ports_on_required[name].each do |p|
                    srv = service_selection[p.component_model]
                    actual_port_name = srv.port_mappings_for_task[p.name]
                    if p = object.find_port(actual_port_name)
                        candidates << p
                    else
                        raise InternalError, "failed to map port from the required facet #{required} to #{object}"
                    end
                end
                candidates
            end

            def has_port?(name)
                !(port_mappings[name] ||= find_all_port_mappings_for(name)).empty?
            end

            def find_port(name)
                unless port_mappings[name]
                    port_mappings[name] = find_all_port_mappings_for(name)
                end
                candidates = port_mappings[name]
                if candidates.size > 1
                    raise AmbiguousPortOnCompositeModel.new(self, required.each_required_model.to_a, name, candidates),
                          "#{name} is an ambiguous port on #{self}: it can be mapped to #{candidates.map(&:to_s).join(', ')}"
                end

                ports = ports_on_required[name]
                unless ports.empty?
                    ports.first.attach(self)
                end
            end

            def self_port_to_component_port(port)
                port_mappings[port.name].first.to_component_port
            end

            def each_port_helper(each_method)
                required.each_required_model do |m|
                    m.send(each_method) do |p|
                        port_mappings[p.name] ||= find_all_port_mappings_for(p.name)
                        if port_mappings[p.name].size == 1
                            yield(p.attach(self))
                        end
                    end
                end
            end

            def each_input_port
                return enum_for(:each_input_port) unless block_given?

                each_port_helper :each_input_port do |p|
                    yield(p)
                end
            end

            def each_output_port
                return enum_for(:each_output_port) unless block_given?

                each_port_helper :each_output_port do |p|
                    yield(p)
                end
            end

            def each_port
                return enum_for(:each_port) if block_given?

                each_input_port(&proc)
                each_output_port(&proc)
            end

            def connect_to(sink, policy = {})
                Syskit.connect(self, sink, policy)
            end

            def to_s
                "#{object}.as(#{required.each_required_model.map(&:to_s).sort.join(',')})"
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m, "_port" => :has_port?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args, "_port" => :find_port
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing
        end
    end
end
