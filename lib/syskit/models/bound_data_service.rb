# frozen_string_literal: true

module Syskit
    module Models
        # Representation of a data service as provided by a component model
        #
        # Instances of this class are usually created by
        # {Models::Component#provides}. Note that bound dynamic services are
        # instances of {BoundDynamicDataService} instead.
        #
        # At the component instance level, each {Models::BoundDataService} is
        # represented by a corresponding {Syskit::BoundDataService}, whose
        # {Syskit::BoundDataService#model} method returns this object. This
        # instance-level object is created with {#bind}
        #
        # Bound data services are _promoted_ from one component model to its
        # submodels, which means that when one does
        #
        #    bound_m = task_m.test_srv
        #    sub_m = task_m.mew_submodel
        #    sub_bound_m = bound_m.test_srv
        #
        # Then sub_bound_m != bound_m as sub_bound_m is bound to sub_m and
        # bound_m is bound to task_m. Use {#same_service?} to check whether
        # two services are different promoted version of the same original
        # service
        class BoundDataService
            include Models::Base
            include MetaRuby::DSLs::FindThroughMethodMissing
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

            def match
                Queries::DataServiceMatcher
                    .new(component_model.match)
                    .with_name(name)
                    .with_model(model)
            end

            # True if this service is not a slave service
            def master?
                !@master
            end

            # True if this is a dynamic service
            def dynamic?
                false
            end

            def to_component_model
                component_model.to_component_model
            end

            def dependency_injection_names
                []
            end

            def eql?(other)
                other.kind_of?(self.class) &&
                    other.full_name == full_name &&
                    other.model == model &&
                    other.component_model == component_model
            end

            def ==(other)
                eql?(other)
            end

            def hash
                [self.class, full_name, component_model].hash
            end

            # The original service from which self has been promoted
            #
            # See {BoundDataService} for more details on promotion
            attr_reader :demoted

            def initialize(name, component_model, master, model, port_mappings)
                @name = name
                @component_model = component_model
                @master = master
                @model = model
                @port_mappings = port_mappings

                @full_name =
                    if master
                        "#{master.name}.#{name}"
                    else
                        name
                    end

                @demoted = self
            end

            def initialize_copy(original)
                super
                @ports = {}
            end

            # (see Component#self_port_to_component_port)
            def self_port_to_component_port(port)
                component_model.find_port(port_mappings_for_task[port.name])
            end

            # [Orocos::Spec::TaskContext] the oroGen model for this service's
            # interface
            def orogen_model
                model.orogen_model
            end

            def find_output_port(name)
                name = name.to_str
                return unless (mapped_name = port_mappings_for_task[name])
                return unless (port = component_model.find_output_port(mapped_name))

                ports[name] ||= OutputPort.new(self, port.orogen_model, name)
            end

            def find_input_port(name)
                name = name.to_str
                return unless (mapped_name = port_mappings_for_task[name])
                return unless (port = component_model.find_input_port(mapped_name))

                ports[name] ||= InputPort.new(self, port.orogen_model, name)
            end

            def each_output_port
                return enum_for(:each_output_port) unless block_given?

                orogen_model.each_output_port do |p|
                    yield(find_output_port(p.name))
                end
            end

            def each_input_port
                return enum_for(:each_input_port) unless block_given?

                orogen_model.each_input_port do |p|
                    yield(find_input_port(p.name))
                end
            end

            # Returns the bound data service object that represents self being
            # attached to a new component model
            def attach(new_component_model, verify: true)
                return self if new_component_model == self

                if verify && !new_component_model.fullfills?(component_model)
                    raise ArgumentError,
                          "cannot attach #{self} on #{new_component_model}: "\
                          "does not fullfill #{component_model}"
                end

                # NOTE: do NOT use #find_data_service here ! find_data_service
                # NOTE: might require some promotion from parent models, which
                # NOTE: is done using #attach !
                result = dup
                result.instance_variable_set :@component_model, new_component_model
                result
            end

            def connect_to(other, policy = {})
                Syskit.connect(self, other, policy)
            end

            def to_s
                "#{component_model.short_name}.#{full_name}"
            end

            def inspect
                to_s
            end

            def short_name
                "#{component_model.short_name}:#{full_name}"
            end

            def pretty_print(pp)
                pp.text "service #{name}(#{model.name}) of"
                pp.nest(2) do
                    pp.breakable
                    component_model.pretty_print(pp)
                end
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
                models = [models] unless models.respond_to?(:each)
                models.each do |required_m|
                    required_m.each_fullfilled_model do |m|
                        return false unless model.fullfills?(m)
                    end
                end
                true
            end

            # Returns the service port that maps to a task port
            #
            # @return [nil,Port]
            def find_port_for_task_port(task_port)
                task_port_name = task_port.name
                port_mappings_for_task.each do |service_port_name, port_name|
                    return find_port(service_port_name) if port_name == task_port_name
                end
                nil
            end

            # Returns the port mappings that should be applied to convert a port
            # from this service to {#component_model}
            #
            # @return [Hash<String,String>] mapping from the name of a port of
            #   self to the name of a port on {#component_model}
            #
            # @see port_mappings_for
            def port_mappings_for_task
                port_mappings_for(model)
            end

            # Returns the port mappings that should be applied from one of the
            # service models provided by {#model} to {#component_model}
            #
            # @param [Model<DataService>] service_model the model of a service
            #   provided by {#model}
            # @return [Hash<String,String>] mapping from the name of a port of
            #   service_model to the name of a port on {#component_model}
            # @see port_mappings_for_task
            def port_mappings_for(service_model)
                unless (result = port_mappings[service_model])
                    raise ArgumentError,
                          "#{service_model} is not provided by #{model.short_name}"
                end
                result
            end

            def each_data_service
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
                return task if task.model == self

                # Shortcut for common case
                if task.model <= component_model
                    return Syskit::BoundDataService.new(task, self)
                end

                unless task.fullfills?(component_model)
                    raise ArgumentError,
                          "cannot bind #{self} on #{task}: "\
                          "does not fullfill #{component_model}"
                end

                # Fullfills, but does not inherit ? component_model may be
                # a data service proxies
                if component_model.placeholder?
                    base_model = component_model.superclass
                    if (base_model_srv = base_model.find_data_service(name))
                        # The data service is from a concrete task model
                        Syskit::BoundDataService.new(task, base_model_srv)
                    else
                        task.find_data_service_from_type(model)
                    end
                # Or maybe we're dealing with dynamic service instanciation
                else
                    resolved = task.find_data_service(name)
                    if !resolved || !resolved.model.same_service?(self)
                        raise InternalError,
                              "#{component_model} is fullfilled by #{task}, "\
                              "but is not inherited by its model #{task.model}. "\
                              "I didn't manage to resolve this, either as a "\
                              "task-to-placeholder mapping, or as a dynamic service"
                    end

                    resolved
                end
            end

            # @deprecated use {#bind} instead
            def resolve(task)
                Roby.warn_deprecated(
                    "#{__method__} is deprecated, use "\
                    "BoundDataService#bind instead"
                )
                bind(task)
            end

            # Creates, in the given plan, a new task matching this service in
            # the given context, and returns the instanciated data service
            #
            # @return [Syskit::BoundDataService]
            def instanciate(plan, context = DependencyInjectionContext.new, options = {})
                bind(component_model.instanciate(plan, context, options))
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
                return enum_for(:each_required_model) unless block_given?

                yield(model)
            end

            extend InstanceRequirements::Auto

            def has_data_service?(name)
                component_model.each_slave_data_service(self) do |slave_m|
                    return true if slave_m.name == name
                end
                false
            end

            def find_data_service(name)
                component_model.each_slave_data_service(self) do |slave_m|
                    return slave_m if slave_m.name == name
                end
                nil
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m, "_srv" => :has_data_service?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    "_srv" => :find_data_service
                ) || super
            end

            # Whether two services are the same service bound to two different interfaces
            #
            # When subclassing, the services are _promoted_ to the new component
            # interface that is being accessed, so in effect when one does
            #
            #    bound_m = task_m.test_srv
            #    sub_m = task_m.mew_submodel
            #    sub_bound_m = bound_m.test_srv
            #
            # Then sub_bound_m != bound_m as sub_bound_m is bound to sub_m and
            # bound_m is bound to task_m. This is important, as we sometimes want
            # to compare services including which interface they're bound to.
            #
            # However, in some cases, we want to know whether two services are
            # actually issues from the same service definition, i.e. have been
            # promoted from the same service. This method performs that comparison
            #
            # @param [BoundDataService] other
            # @return [Boolean]
            def same_service?(other)
                other.demoted == demoted
            end

            # The selection object that represents self being selected for
            # requirements
            #
            # @param [#to_instance_requirements] requirements the requirements
            #   for which self is being selected
            # @return [InstanceSelection]
            def selected_for(requirements)
                InstanceSelection.new(
                    nil, to_instance_requirements,
                    requirements.to_instance_requirements
                )
            end

            DRoby = Struct.new :name, :component_model, :master, :model do
                def proxy(peer)
                    component_model = peer.local_object(self.component_model)
                    if (srv = component_model.find_data_service(name))
                        srv
                    else
                        BoundDataService.new(
                            name, component_model,
                            peer.local_object(master), peer.local_object(model),
                            {}
                        )
                    end
                end
            end

            def droby_dump(peer)
                DRoby.new(
                    name, peer.dump(component_model),
                    peer.dump(master), peer.dump(model)
                )
            end
        end
    end
end
