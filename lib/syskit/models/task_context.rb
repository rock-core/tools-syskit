module Syskit
    module Models
        module TaskContext
            include Base

            # [Hash{Orocos::Spec::TaskContext => TaskContext}] a cache of
            # mappings from oroGen task context models to the corresponding
            # Syskit task context model
            attribute(:orogen_model_to_syskit_model) { Hash.new }

            # Clears all registered submodels
            #
            # On TaskContext, it also clears all orogen-to-syskit model mappings
            def deregister_submodels(set)
                super
                set.each do |m|
                    Syskit::TaskContext.orogen_model_to_syskit_model.delete(m.orogen_model)
                end
                if @proxy_task_models
                    set.each do |m|
                        if m.respond_to?(:proxied_data_services)
                            proxy_task_models.delete(m.proxied_data_services.to_set)
                        end
                    end
                end
            end

            # Checks whether a syskit model exists for the given orogen model
            def has_model_for?
                !!orogen_model_to_syskit_model[orogen_model]
            end

            # Returns the syskit model for the given oroGen model
            #
            # @raises ArgumentError if no syskit model exists 
            def model_for(orogen_model)
                if m = orogen_model_to_syskit_model[orogen_model]
                    return m
                else raise ArgumentError, "there is no syskit model for #{orogen_model.name}"
                end
            end

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def define_from_orogen(orogen_model, options = Hash.new)
                options = Kernel.validate_options options,
                    :register => false

                superclass = orogen_model.superclass
                if !superclass # we are defining a root model
                    supermodel = Syskit::TaskContext
                elsif !(supermodel = orogen_model_to_syskit_model[superclass])
                    supermodel = define_from_orogen(superclass)
                end
                klass = supermodel.new_submodel(:orogen_model => orogen_model)
                
                # Define specific events for the extended states (if there is any)
                state_events = Hash.new
                orogen_model.states.each do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    if type == :toplevel
                        klass.event event_name, :terminal => (name == 'EXCEPTION' || name == 'FATAL_ERROR')
                    else
                        klass.event event_name, :terminal => (type == :exception || type == :fatal_error)
                        if type == :fatal
                            klass.forward event_name => :fatal_error
                        elsif type == :exception
                            klass.forward event_name => :exception
                        elsif type == :error
                            klass.forward event_name => :runtime_error
                        end
                    end

                    state_events[name.to_sym] = event_name
                end
                if supermodel && supermodel.state_events
                    state_events = state_events.merge(supermodel.state_events)
                end

                klass.state_events = state_events
                if options[:register] && orogen_model.name
                    namespace, basename = orogen_model.name.split '::'
                    namespace = namespace.camelcase(:upper)
                    namespace =
                        begin
                            constant("::#{namespace}")
                        rescue NameError
                            Object.const_set(namespace, Module.new)
                        end
                    namespace.const_set(basename.camelcase(:upper), klass)
                end

                klass
            end

            def require_dynamic_service(service_model, options)
                # Verify that there are dynamic ports in orogen_model that match
                # the ports in service_model.orogen_model
                service_model.each_input_port do |p|
                    if !has_dynamic_input_port?(p.name, p.type)
                        raise ArgumentError, "there are no dynamic input ports declared in #{short_name} that match #{p.name}:#{p.type_name}"
                    end
                end
                service_model.each_output_port do |p|
                    if !has_dynamic_output_port?(p.name, p.type)
                        raise ArgumentError, "there are no dynamic output ports declared in #{short_name} that match #{p.name}:#{p.type_name}"
                    end
                end
                
                # Unlike #data_service, we need to add the service's interface
                # to our own
                Syskit::Models.merge_orogen_task_context_models(orogen_model, [service_model.orogen_model])

                # Then we can add the service
                provides(service_model, options)
            end

            # Creates a Ruby class which represents the set of properties that
            # the task context has. The returned class will initialize its
            # members to the default values declared in the oroGen files
            def config_type_from_properties(register = true)
                if @config_type
                    return @config_type
                end

                default_values = Hash.new
                task_model = self

                config = Class.new do
                    class << self
                        attr_accessor :name
                    end
                    @name = "#{task_model.name}::ConfigType"

                    attr_reader :property_names

                    task_model.orogen_model.each_property do |p|
                        property_type = Orocos.typelib_type_for(p.type)
		    	singleton_class.class_eval do
			    attr_reader p.name
			end
			instance_variable_set "@#{p.name}", property_type

                        default_values[p.name] =
                            if p.default_value
                                Typelib.from_ruby(p.default_value, property_type)
                            else
                                value = property_type.new
                                value.zero!
                                value
                            end

                        if property_type < Typelib::CompoundType || property_type < Typelib::ArrayType
                            attr_accessor p.name
                        else
                            define_method(p.name) do
                                Typelib.to_ruby(instance_variable_get("@#{p.name}"))
                            end
                            define_method("#{p.name}=") do |value|
                                value = Typelib.from_ruby(value, property_type)
                                instance_variable_set("@#{p.name}", value)
                            end
                        end
                    end

                    define_method(:initialize) do
                        default_values.each do |name, value|
                            instance_variable_set("@#{name}", value.dup)
                        end
                        @property_names = default_values.keys
                    end

                    class_eval <<-EOD
                    def each
                        property_names.each do |name|
                            yield(name, send(name))
                        end
                    end
                    EOD
                end
		if register && !self.constants.include?(:Config)
		    self.const_set(:Config, config)
		end
                @config_type = config
            end

            # [Orocos::Spec::TaskContext] The oroGen model that represents this task context model
            attribute(:orogen_model) { Orocos::Spec::TaskContext.new }

            # A state_name => event_name mapping that maps the component's
            # state names to the event names that should be emitted when it
            # enters a new state.
            attribute(:state_events) { Hash.new }

            # Create a new TaskContext model
            #
            # @option options [String] name (nil) forcefully set a name for the model.
            #   This is only useful for "anonymous" models, i.e. models that are
            #   never assigned in the Ruby constant hierarchy
            # @option options [Orocos::Spec::TaskContext] orogen_model (nil) the
            #   oroGen model that should be used. If not given, an empty model
            #   is created, possibly with the name given to the method as well.
            def new_submodel(options = Hash.new, &block)
                options = Kernel.validate_options options,
                    :name => nil, :orogen_model => nil
                model = Class.new(self)
                if orogen_model = options[:orogen_model]
                    model.orogen_model = orogen_model
                else
                    model.orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, options[:name])
                    model.orogen_model.subclasses self.orogen_model
                    model.state_events = self.state_events.dup
                end
                orogen_model_to_syskit_model[model.orogen_model] = model
                if block
                    model.orogen_model.instance_eval(&block)
                end
                register_submodel(model)
                model
            end

            def worstcase_processing_time(value)
                orogen_model.worstcase_processing_time(value)
            end

            def each_event_port(&block)
                orogen_model.each_event_port(&block)
            end

            # [Hash{Array<DataService> => Models::Task}] a cache of models
            # creates in #proxy_task_model
            attribute(:proxy_task_models) { Hash.new }

            # Create a task model that can be used as a placeholder in a Roby
            # plan for this task model and the following service models.
            #
            # @see Syskit.proxy_task_model_for
            def proxy_task_model(service_models)
                service_models = service_models.to_set
                if task_model = proxy_task_models[service_models]
                    return task_model
                end

                name = "Syskit::PlaceholderTask<#{self.short_name},#{service_models.map(&:short_name).sort.join(",")}>"
                model = specialize(name)
                model.abstract
                model.include PlaceholderTask
                model.proxied_data_services = service_models.dup
		model.fullfilled_model = [self, model.proxied_data_services, Hash.new]

                Syskit::Models.merge_orogen_task_context_models(model.orogen_model, service_models.map(&:orogen_model))
                service_models.each do |m|
                    model.provides m
                end
                proxy_task_models[service_models] = model
                model
            end
        end
    end

    # Model used to create a placeholder task from a concrete task model,
    # when a mix of data services and task context model cannot yet be
    # mapped to an actual task context model yet
    module PlaceholderTask
        module ClassExtension
            attr_accessor :proxied_data_services
        end

        def proxied_data_services
            self.model.proxied_data_services
        end
    end

    # This method creates a task model that can be used to represent the
    # models listed in +models+ in a plan. The returned task model is
    # obviously abstract
    def self.proxy_task_model_for(models)
        task_models, service_models = models.partition { |t| t < Component }
        if task_models.size > 1
            raise ArgumentError, "cannot create a proxy for multiple component models at the same time"
        end
        task_model = task_models.first || TaskContext

        # If all that is required is a proper task model, just return it
        if service_models.empty?
            return task_model
        end

        task_model.proxy_task_model(service_models)
    end
end

