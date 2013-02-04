module Syskit
    module Models
        # Representation of a data service as provided by a component model
        class BoundDataService
            include Models::PortAccess

            # The task model which provides this service
            attr_reader :component_model
            # The service name
            attr_reader :name
            # The master service (if there is one)
            attr_reader :master
            # The service model
            attr_reader :model
            # The mappings needed between the ports in the service interface and
            # the actual ports on the component
            attr_reader :port_mappings

            # The service's full name, i.e. the name with which it is referred
            # to in the task model
            attr_reader :full_name

            # True if this service is not a slave service
            def master?; !@master end

            def ==(other)
                other.kind_of?(self.class) &&
                    other.full_name == full_name &&
                    other.component_model == component_model
            end

            def initialize(name, component_model, master, model, port_mappings)
                @name, @component_model, @master, @model, @port_mappings = 
                    name, component_model, master, model, port_mappings

                @full_name =
                    if master
                        "#{master.name}.#{name}"
                    else
                        name
                    end
            end

            # (see Component#self_port_to_component_port)
            def self_port_to_component_port(port)
                return component_model.find_port(port_mappings_for_task[port.name])
            end

            # [Orocos::Spec::TaskContext] the oroGen model for this service's
            # interface
            def orogen_model
                model.orogen_model
            end

            def find_output_port(name)
                name = name.to_str
                if (mapped = port_mappings_for_task[name]) && (port = component_model.find_output_port(mapped))
                    ports[name] ||= OutputPort.new(self, port.orogen_model, name)
                end
            end

            def find_input_port(name)
                name = name.to_str
                if (mapped = port_mappings_for_task[name]) && (port = component_model.find_input_port(mapped))
                    ports[name] ||= InputPort.new(self, port.orogen_model, name)
                end
            end

            def each_output_port
                return enum_for(:each_output_port) if !block_given?
                orogen_model.each_output_port do |p|
                    yield(find_output_port(p.name))
                end
            end

            def each_input_port
                return enum_for(:each_input_port) if !block_given?
                orogen_model.each_input_port do |p|
                    yield(find_input_port(p.name))
                end
            end

            def attach(new_component_model)
                result = dup
                result.instance_variable_set :@component_model, new_component_model
                result
            end

            def to_s
                "#{component_model.short_name}.#{full_name}"
            end

            def short_name
                "#{component_model.short_name}:#{full_name}"
            end

            # Returns a view of this service as a provider of +service_model+
            #
            # It allows to transparently apply port mappings as if +self+ was a
            # service of type +service_model+
            def as(service_model)
                result = dup
                result.instance_variable_set(:@model, service_model)

                mappings = port_mappings.dup
                mappings.delete_if do |srv, _|
                    !service_model.fullfills?(srv)
                end
                result.instance_variable_set(:@port_mappings, mappings)
                result.ports.clear
                result
            end

            def fullfills?(models)
                if !models.respond_to?(:each)
                    models = [models]
                end
                components, services = models.partition { |m| m <= Syskit::Component }
                components.empty? &&
                    (services.empty? || self.model.fullfills?(services))
            end

            # Returns the port mappings that should be applied from the service
            # model +model+ to the providing task
            #
            # The returned value is a hash of the form
            #
            #   service_port_name => task_port_name
            #
            def port_mappings_for_task
                port_mappings_for(model)
            end

            # Returns the port mappings that should be applied from the service
            # model +service_model+ to the providing task
            #
            # The returned value is a hash of the form
            #
            #   service_port_name => task_port_name
            #
            def port_mappings_for(service_model)
                if !(result = port_mappings[service_model])
                    raise ArgumentError, "#{service_model} is not provided by #{model.short_name}"
                end
                result
            end

            def each_data_service(&block)
                self
            end

            # Enumerates the data services that are slave of this one
            def each_slave_data_service(&block)
                component_model.each_slave_data_service(self, &block)
            end

            def each_fullfilled_model
                return enum_for(:each_fullfilled_model) if !block_given?
                yield(component_model)
                model.ancestors.each do |m|
                    if m <= Component || m <= DataService
                        yield(m)
                    end
                end
            end

            # Returns the BoundDataService object that binds this provided
            # service to an actual task
            def bind(task)
                if !task.fullfills?(component_model)
                    raise ArgumentError, "cannot bind #{self} on #{task}: does not fullfill #{component_model}"
                end
                Syskit::BoundDataService.new(task, self)
            end

            # Creates, in the given plan, a new task matching this service in
            # the given context, and returns the instanciated data service
            def instanciate(plan, context = DependencyInjectionContext.new, options = Hash.new)
                to_instance_requirements.instanciate(plan, context, options)
            end

            # Returns the BoundDataService object that binds this provided
            # service to an actual task
            def resolve(task)
                bind(component_model.resolve(task))
            end

            # Generates the InstanceRequirements object that represents +self+
            # best
            #
            # @return [Syskit::InstanceRequirements]
            def to_instance_requirements
                req = component_model.to_instance_requirements
                req.select_service(self)
                req
            end

            def method_missing(m, *args, &block)
                if !args.empty? || block
                    return super
                end
                name = m.to_s
                if (name =~ /^(\w+)_srv$/) && (subservice = component_model.find_data_service("#{full_name}.#{$1}"))
                    return subservice
                elsif (name =~ /^(\w+)_port$/) && (p = find_port($1))
                    return p
                end
                super
            end

            DRoby = Struct.new :name, :component_model, :master, :model do
                def proxy(peer)
                    component_model = peer.local_object(self.component_model)
                    if srv = component_model.find_data_service(name)
                        return srv
                    else
                        BoundDataService.new(name, component_model, peer.local_object(master), peer.local_object(model), Hash.new)
                    end
                end
            end
            def droby_dump(peer); DRoby.new(name, component_model.droby_dump(peer), master.droby_dump(peer), model.droby_dump(peer)) end
        end
    end
end

