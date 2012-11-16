module Syskit
    module Models
        module TaskContext
            include Base

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def define_from_orogen(task_spec, system_model)
                superclass = task_spec.superclass
                if !(supermodel = Roby.app.orocos_tasks[superclass.name])
                    supermodel = define_from_orogen(superclass, system_model)
                end
                klass = system_model.
                    task_context(task_spec.name, :child_of => supermodel)

                klass.instance_variable_set :@orogen_spec, task_spec
                
                # Define specific events for the extended states (if there is any)
                state_events = { :EXCEPTION => :exception, :FATAL_ERROR => :fatal_error, :RUNTIME_ERROR => :runtime_error }
                task_spec.states.each do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    klass.event event_name
                    if type == :fatal
                        klass.forward event_name => :fatal_error
                    elsif type == :exception
                        klass.forward event_name => :exception
                    elsif type == :error
                        klass.forward event_name => :runtime_error
                    end

                    state_events[name.to_sym] = event_name
                end
                if supermodel && supermodel.state_events
                    state_events = state_events.merge(supermodel.state_events)
                end

                klass.instance_variable_set :@state_events, state_events
                if task_spec.name
                    Roby.app.orocos_tasks[task_spec.name] = klass
                end
                klass
            end

            def require_dynamic_service(service_model, options)
                # Verify that there are dynamic ports in orogen_spec that match
                # the ports in service_model.orogen_spec
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
                Syskit.merge_orogen_interfaces(orogen_spec, [service_model.orogen_spec])

                # Then we can add the service
                provides(service_model, options)
            end

            def create(spec_or_name = nil, &block)
                if block || !spec_or_name || spec_or_name.respond_to?(:to_str)
                    task_spec = Syskit.create_orogen_interface(spec_or_name)
                    if block
                        task_spec.instance_eval(&block)
                    end
                else
                    task_spec = spec_or_name
                end
                
                superclass = task_spec.superclass
                if !(supermodel = Roby.app.orocos_tasks[superclass.name])
                    supermodel = create(superclass)
                end

                klass = Class.new(supermodel)
                klass.instance_variable_set :@orogen_spec, task_spec

                if task_spec.name
                    roby_name = task_spec.name.split('::').
                        map { |s| s.camelcase(:upper) }.
                        join("::")

                    klass.instance_variable_set :@name, roby_name
                end
                
                # Define specific events for the extended states (if there is any)
                state_events = {
                    :EXCEPTION => :exception,
                    :FATAL_ERROR => :fatal_error,
                    :RUNTIME_ERROR => :runtime_error }
                task_spec.states.each do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    klass.event event_name
                    if type == :fatal
                        klass.forward event_name => :fatal_error
                    elsif type == :exception
                        klass.forward event_name => :exception
                    elsif type == :error
                        klass.forward event_name => :runtime_error
                    end

                    state_events[name.to_sym] = event_name
                end
                if supermodel && supermodel.state_events
                    state_events = state_events.merge(supermodel.state_events)
                end
                klass.instance_variable_set :@state_events, state_events

                klass
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

                    task_model.orogen_spec.each_property do |p|
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

            attr_accessor :name
            # The Orocos::Generation::TaskContext that represents this
            # deployed task context.
            attr_accessor :orogen_spec

            def interface
                orogen_spec
            end
            def interface=(spec)
                self.orogen_spec = spec
            end

            # A state_name => event_name mapping that maps the component's
            # state names to the event names that should be emitted when it
            # enters a new state.
            attr_accessor :state_events

            def to_s
                services = each_data_service.map do |name, srv|
                        "#{name}[#{srv.model.short_name}]"
                end.join(", ")
                if private_specialization?
                    "#<specialized from #{superclass.name} services: #{services}>"
                else
                    "#<#{name} services: #{services}>"
                end
            end

            # :attr: private_specialization?
            #
            # If true, this model is used internally to represent
            # instanciated dynamic services. Otherwise, it is an actual
            # task context model
            attr_predicate :private_specialization?, true

            # Creates a private specialization of the current model
            def specialize(name)
                if self == TaskContext
                    raise "#specialize should not be used to create a specialization of TaskContext. Use only on \"real\" task context models"
                end
                klass = new_submodel
                klass.private_specialization = true
                klass.private_model
                klass.name = name
                # The oroGen spec name should be the same, as we need that
                # for logging. Note that the layer itself does not care about the
                # name
                klass.orogen_spec  = Syskit.create_orogen_interface(self.name)
                klass.state_events = state_events.dup
                Syskit.merge_orogen_interfaces(klass.orogen_spec, [orogen_spec])
                klass
            end

            def worstcase_processing_time(value)
                orogen_spec.worstcase_processing_time(value)
            end

            def each_event_port(&block)
                orogen_spec.each_event_port(&block)
            end
        end
    end
end

