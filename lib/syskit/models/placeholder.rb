# frozen_string_literal: true

module Syskit
    module Models
        # @api private
        #
        # Base implementation of the creation of models that represent an arbitrary
        # mix of a task model and a set of data services.
        #
        # Its most common usage it to represent a single data service (which is seen
        # as a {Component} model with an extra data service). It can also be used to
        # represent a taskcontext model that should have an extra data service at
        # dependency-injection time because of e.g. dynamic service instantiation.
        module Placeholder
            # The list of data services that are being proxied
            attr_accessor :proxied_data_service_models
            # The base component model that is being proxied
            attr_accessor :proxied_component_model

            def to_instance_requirements
                Syskit::InstanceRequirements.new([self])
            end

            def each_fullfilled_model(&block)
                fullfilled_model.each(&block)
            end

            # Whether this proxies only services or not
            def component_model?
                proxied_component_model != Syskit::Component
            end

            def fullfilled_model
                result = Set.new
                if component_model?
                    proxied_component_model.each_fullfilled_model do |m|
                        result << m
                    end
                end
                proxied_data_service_models.each do |srv|
                    srv.each_fullfilled_model do |m|
                        result << m
                    end
                end
                unless component_model?
                    result << AbstractComponent
                end
                result
            end

            def each_required_model
                return enum_for(:each_required_model) unless block_given?

                if component_model?
                    yield(proxied_component_model)
                end
                proxied_data_service_models.each do |m|
                    yield(m)
                end
            end

            def merge(other_model)
                if other_model.kind_of?(Models::BoundDataService)
                    return other_model.merge(self)
                end

                task_model = proxied_component_model
                service_models = proxied_data_service_models
                other_service_models = []
                if other_model.placeholder?
                    task_model = task_model.merge(other_model.proxied_component_model)
                    other_service_models = other_model.proxied_data_service_models
                else
                    task_model = task_model.merge(other_model)
                end

                model_list = Models.merge_model_lists(service_models, other_service_models)

                # Try to keep the type of submodels of Placeholder for as
                # long as possible. We re-create a proxy only when needed
                if self <= task_model && model_list.all? { |m| service_models.include?(m) }
                    return self
                elsif other_model <= task_model && model_list.all? { |m| other_service_models.include?(m) }
                    return other_model
                end

                Placeholder.for(model_list, component_model: task_model)
            end

            def each_output_port
                return enum_for(:each_output_port) unless block_given?

                @output_port_models.each_value do |list|
                    list.each { |p| yield(p) }
                end
            end

            def each_input_port
                return enum_for(:each_input_port) unless block_given?

                @input_port_models.each_value do |list|
                    list.each { |p| yield(p) }
                end
            end

            def each_port
                return enum_for(:each_port) unless block_given?

                each_output_port { |p| yield(p) }
                each_input_port { |p| yield(p) }
            end

            def find_output_port(name)
                if list = @output_port_models[name]
                    list.first
                end
            end

            def find_input_port(name)
                if list = @input_port_models[name]
                    list.first
                end
            end

            def find_port(name)
                find_output_port(name) || find_input_port(name)
            end

            def has_port?(name)
                @input_port_models.key?(name.to_s) ||
                    @output_port_models.key?(name.to_s)
            end

            def update_proxy_mappings
                @output_port_models = {}
                @input_port_models = {}
                each_required_model do |m|
                    m.each_output_port do |port|
                        (@output_port_models[port.name] ||= []) << port.attach(self)
                    end
                    m.each_input_port  do |port|
                        (@input_port_models[port.name] ||= []) << port.attach(self)
                    end
                end
            end

            def placeholder?
                true
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m,
                    "_port" => :has_port?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    "_port" => :find_port
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            # Encapsulation of the methods that allow to create placeholder
            # models
            #
            # This is separated to ease the creation of specialized placeholder
            # types such as {Actions::Profile::Tag}
            module Creation
                # Create a new specialized placeholder type that provides the
                # same API than Placeholder
                def new_specialized_placeholder(task_extension: Syskit::Placeholder, &block)
                    self_ = self
                    creation = Module.new do
                        include self_::Creation
                    end
                    model = Module.new do
                        include self_
                        const_set(:Creation, creation)
                        extend creation
                    end

                    if task_extension != Syskit::Placeholder
                        creation.class_eval do
                            define_method(:task_extension) { task_extension }
                        end
                    end

                    if block
                        model.class_eval(&block)
                    end
                    model
                end

                # Return the module that should be included in the newly created
                # models
                #
                # It defaults to {Syskit::Placeholder}
                def task_extension
                    Syskit::Placeholder
                end

                # Create a task model that is an aggregate of all the provided
                # models (components and services)
                #
                # You usually should use {proxy_component_model_for} instead of this
                #
                # @param (see resolve_models_argument)
                # @param [String] as the name of the newly created model
                # @return [Component]
                def create_for(models, component_model: nil, as: nil)
                    task_model, service_models, =
                        resolve_models_argument(models, component_model: component_model)

                    name_models = service_models.map(&:to_s).sort.join(",")
                    if task_model != Syskit::Component
                        name_models = "#{task_model},#{name_models}"
                    end
                    model = task_model.specialize(as || format("#{self}<%s>", name_models))
                    model.abstract
                    model.concrete_model = nil
                    model.include task_extension
                    model.extend  self
                    model.proxied_component_model = task_model
                    model.proxied_data_service_models = service_models.dup
                    model.update_proxy_mappings

                    service_models.each_with_index do |m, i|
                        model.provides m, as: "m#{i}"
                    end
                    model
                end

                # Returns a component model that can be used to represent an
                # instance of an arbitrary set of models in a plan
                #
                # Unlike {create_for}, it will create a new model only if needed,
                # that is if both data services are actually requested, and if
                # {.for} has not yet been called with the same parameter (in which
                # case the model created then will be returned)
                #
                # This is the main entry point. It will cache created models so that
                # proxying the same set of services on the same component model
                # returns the same result.
                #
                # @param (see create_for)
                def for(models, component_model: nil, as: nil)
                    task_model, service_models, service =
                        resolve_models_argument(models, component_model: component_model)

                    service_models = service_models.to_set
                    if service_models.empty?
                        proxy_component_model = task_model
                    elsif cached_model = task_model.find_placeholder_model(service_models, self)
                        proxy_component_model = cached_model
                    else
                        service_models = service_models.to_set
                        proxy_component_model =
                            create_for(service_models, component_model: task_model, as: as)
                        task_model.register_placeholder_model(proxy_component_model, service_models, self)
                    end

                    if service
                        service.attach(proxy_component_model)
                    else proxy_component_model
                    end
                end

                # @api private
                #
                # Resolves the base task model and set of service models that should be used
                # to create a proxy task model for the given component and/or service models
                #
                # @param [Set<Component,DataService,BoundDataService>] the set of component
                #   and data service models.  There can be only one component model (as per
                #   Ruby's single-inheritance system). If a bound data service is provided,
                #   its underlying component model is used as base model and the service is
                #   returned instead of the plain task
                # @param [Component,nil] component_model historically, methods were
                #   called with a mix of component models and data service models.
                #   If the component model ({Component} or {BoundDataService}) is
                #   known, it should be given to {.create_proxy_component_model_for} and
                #   {.proxy_component_model_for} through this parameter to avoid
                #   re-resolving it.
                # @return [Component,Array<DataService>,(BoundDataService,nil)
                #
                # This is a helper method for {.create_proxy_component_model_for} and
                # {.proxy_component_model_for}
                def resolve_models_argument(models, component_model: nil)
                    if component_model
                        if component_model.respond_to?(:component_model)
                            bound_service = component_model
                            component_model = component_model.component_model
                        end
                        models = models.find_all { |srv| !component_model.fullfills?(srv) }
                        return component_model, models, bound_service
                    end

                    service = nil
                    models = models.map do |m|
                        if m.respond_to?(:component_model)
                            if service
                                raise ArgumentError, "more than one bound data service given: #{service} and #{m}"
                            end

                            service = m
                            m.component_model
                        else m
                        end
                    end
                    task_models, service_models = models.partition { |t| t <= Syskit::Component }
                    if task_models.empty?
                        [Syskit::Component, service_models, service]
                    elsif task_models.size == 1
                        task_model = task_models.first
                        service_models.delete_if { |srv| task_model.fullfills?(srv) }
                        [task_model, service_models, service]
                    else
                        raise ArgumentError, "cannot create a proxy for multiple component models at the same time"
                    end
                end
            end
            extend Creation
        end
    end

    # @api private
    #
    # @deprecated use {Placeholder.resolve_requirements} instead
    def self.resolve_proxy_task_model_requirements(models)
        Roby.warn_deprecated "Syskit.resolve_proxy_task_model_requirements is deprecated use Models::Placeholder.resolve_models_argument instead"
        Models::Placeholder.resolve_requirements(models)
    end

    # @deprecated use {Placeholder.create_for}
    def self.create_proxy_task_model_for(models, **options)
        Roby.warn_deprecated "Syskit.create_proxy_task_model is deprecated use Models::Placeholder.create_for instead"
        Models::Placeholder.create_for(models, **options)
    end

    # @deprecated use {Placholder.for}
    def self.proxy_task_model_for(models)
        Roby.warn_deprecated "Syskit.proxy_task_model_for is deprecated use Models::Placeholder.for instead"
        Models::Placeholder.for(models)
    end

    # @deprecated has been renamed into Placeholder
    autoload :PlaceholderTask, "syskit/models/placeholder_task"
end
