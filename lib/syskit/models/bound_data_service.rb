module Syskit
    module Models
        # Representation of a data service as provided by a component model
        class BoundDataService
            include Models::Base
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

            def to_component_model; component_model.to_component_model end

            def dependency_injection_names; Array.new end

            def eql?(other)
                other.kind_of?(self.class) &&
                    other.full_name == full_name &&
                    other.component_model == component_model
            end

            def ==(other)
                eql?(other)
            end

            def hash; [self.class, full_name, component_model].hash end

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

            # Returns the bound data service object that represents self being
            # attached to a new component model
            def attach(new_component_model)
                if new_component_model == self
                    return self
                elsif !new_component_model.fullfills?(component_model)
                    raise ArgumentError, "cannot attach #{self} on #{new_component_model}: does not fullfill #{component_model}"
                end

                result = dup
                result.instance_variable_set :@component_model, new_component_model
                result
            end

            def connect_to(other, policy = Hash.new)
                Syskit.connect(self, other, policy)
            end

            def self_port_to_component_port(port)
                component_model.find_port(port_mappings_for_task[port.name])
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
            #
            # The original state of self (before as was called) can be retrieved
            # by calling {as_real_model} on the returned value
            #
            # @return [BoundDataService]
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

            # Returns the actual bound data service when the receiver is the
            # return value of {as}
            #
            # @return [BoundDataService]
            def as_real_model
                component_model.find_data_service(full_name)
            end

            def fullfilled_model
                [model]
            end

            # Returns true if self provides all models in models
            def fullfills?(models)
                if !models.respond_to?(:each)
                    models = [models]
                end
                models.each do |required_m|
                    required_m.each_fullfilled_model do |m|
                        return false if !self.model.fullfills?(m)
                    end
                end
                true
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

            def each_fullfilled_model(&block)
                model.each_fullfilled_model(&block)
            end

            def merge(other_model)
                m = other_model.merge(component_model)
                attach(m)
            end

            # Returns the BoundDataService object that binds this provided
            # service to an actual task
            #
            # @param [Component,Syskit::BoundDataService] task the component
            #   that we should bind to. It can itself be a data service
            # @return [Syskit::BoundDataService]
            def bind(task)
                if task.model == self
                    # !!! task is a BoundDataService
                    return task
                elsif !task.fullfills?(component_model)
                    raise ArgumentError, "cannot bind #{self} on #{task}: does not fullfill #{component_model}"
                end
                Syskit::BoundDataService.new(task, self)
            end

            # Creates, in the given plan, a new task matching this service in
            # the given context, and returns the instanciated data service
            #
            # @return [Syskit::BoundDataService]
            def instanciate(plan, context = DependencyInjectionContext.new, options = Hash.new)
                bind(component_model.instanciate(plan, context, options))
            end

            # Returns the BoundDataService object that binds this provided
            # service to an actual task
            #
            # @return [Syskit::BoundDataService]
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

            def each_required_model
                return enum_for(:each_required_model) if !block_given?
                yield(model)
            end

            extend InstanceRequirements::Auto

            def find_data_service(name)
                component_model.each_slave_data_service(self) do |slave_m|
                    if slave_m.name == name
                        return slave_m
                    end
                end
                nil
            end

            def method_missing(m, *args, &block)
                case m.to_s
                when /^(\w+)_srv$/
                    srv_name = $1
                    if srv = self.find_data_service(srv_name)
                        if !args.empty?
                            raise ArgumentError, "#{m} expects no arguments, got #{args.size}"
                        end
                        return srv
                    else
                        raise NoMethodError, "#{self} has no slave service called #{srv_name}"
                    end
                end
                super
            end

            # The selection object that represents self being selected for
            # requirements
            #
            # @param [#to_instance_requirements] requirements the requirements
            #   for which self is being selected
            # @return [InstanceSelection]
            def selected_for(requirements)
                InstanceSelection.new(nil, self.to_instance_requirements, requirements.to_instance_requirements)
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

