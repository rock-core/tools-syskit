module Syskit
    module Models
        # This module contains the model-level API for the task context models
        #
        # It is used to extend every subclass of Syskit::TaskContext
        module TaskContext
            include Models::Base
            include Models::PortAccess
            include Models::OrogenBase

            # Clears all registered submodels
            #
            # On TaskContext, it also clears all orogen-to-syskit model mappings
            def deregister_submodels(set)
                if !super
                    return
                end

                if @proxy_task_models
                    set.each do |m|
                        if m.respond_to?(:proxied_data_services)
                            proxy_task_models.delete(m.proxied_data_services.to_set)
                        end
                    end
                end
                true
            end

            # Generates a hash of oroGen-level state names to Roby-level event
            # names
            #
            # @return [{Symbol=>Symbol}]
            def make_state_events
                orogen_model.states.each do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    if type == :toplevel
                        event event_name, :terminal => (name == 'EXCEPTION' || name == 'FATAL_ERROR')
                    else
                        event event_name, :terminal => (type == :exception || type == :fatal_error)
                        if type == :fatal
                            forward event_name => :fatal_error
                        elsif type == :exception
                            forward event_name => :exception
                        elsif type == :error
                            forward event_name => :runtime_error
                        end
                    end

                    self.state_events[name.to_sym] = event_name
                end
            end

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def define_from_orogen(orogen_model, options = Hash.new)
                options = Kernel.validate_options options,
                    :register => false
                if model = find_model_by_orogen(orogen_model) # already defined, probably because of dependencies
                    return model
                end

                superclass = orogen_model.superclass
                if !superclass # we are defining a root model
                    supermodel = Syskit::TaskContext
                else
                    supermodel = find_model_by_orogen(superclass) ||
                        define_from_orogen(superclass, :register => options[:register])
                end
                klass = supermodel.new_submodel(:orogen_model => orogen_model)

                if options[:register] && orogen_model.name
                    register_syskit_model_from_orogen_name(klass)
                end

                klass
            end

            # Registers the given syskit model on the class hierarchy, using the
            # (camelized) orogen name as a basis
            #
            # If there is a constant clash, the model will not be registered but
            # its #name method will return the "right" value enclosed in <>
            #
            # @return [Boolean] true if the model could be registered and false
            # otherwise
            def register_syskit_model_from_orogen_name(model)
                orogen_model = model.orogen_model

                namespace, basename = orogen_model.name.split '::'
                namespace = namespace.camelcase(:upper)
                namespace =
                    if Object.const_defined_here?(namespace)
                        Object.const_get(namespace)
                    else 
                        Object.const_set(namespace, Module.new)
                    end

                basename = basename.camelcase(:upper)
                if namespace.const_defined_here?(basename)
                    warn "there is already a constant with the name #{namespace.name}::#{basename}, I am not registering the model for #{orogen_model.name} there"
                    model.name = "<#{namespace}::#{basename}>"
                    false
                else
                    namespace.const_set(basename, model)
                    true
                end
            end

            # [Orocos::Spec::TaskContext] The oroGen model that represents this task context model
            attribute(:orogen_model) { Orocos::Spec::TaskContext.new }

            # A state_name => event_name mapping that maps the component's
            # state names to the event names that should be emitted when it
            # enters a new state.
            define_inherited_enumerable(:state_event, :state_events, :map => true) { Hash.new }

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
                model.permanent_model = false
                if options[:name]
                    model.name = options[:name]
                end

                if orogen_model = options[:orogen_model]
                    model.orogen_model = orogen_model
                else
                    model.setup_submodel
                end
                register_submodel(model)
                
                if block
                    evaluation = DataServiceModel::BlockInstanciator.new(model)
                    evaluation.instance_eval(&block)
                end
                model.make_state_events
                model
            end

            # Sets up self on the basis of {#supermodel}
            #
            # @param [String] name an optional name for this submodel
            # @return [void]
            def setup_submodel
                super

                self.orogen_model = Orocos::Spec::TaskContext.new(Orocos.master_project, self.name)
                self.orogen_model.subclasses supermodel.orogen_model
            end

            def worstcase_processing_time(value)
                orogen_model.worstcase_processing_time(value)
            end

            def each_event_port(&block)
                orogen_model.each_event_port(&block)
            end

            # Returns the configuration hash for the given configuration names,
            # given this task context
            def resolve_configuration(*names)
                if conf = Orocos.conf.conf[orogen_model.name].conf(names, true)
                    conf.map_value { |k, v| Typelib.to_ruby(v) }
                else raise ArgumentError, "there is no configuration #{names} for #{self}"
                end
            end
        end
    end
end

