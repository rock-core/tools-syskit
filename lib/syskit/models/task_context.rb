module Syskit
    module Models
        # This module contains the model-level API for the task context models
        #
        # It is used to extend every subclass of Syskit::TaskContext
        module TaskContext
            include Models::Base
            include Models::PortAccess

            # [Hash{Orocos::Spec::TaskContext => TaskContext}] a cache of
            # mappings from oroGen task context models to the corresponding
            # Syskit task context model
            attribute(:orogen_model_to_syskit_model) { Hash.new }

            # Clears all registered submodels
            #
            # On TaskContext, it also clears all orogen-to-syskit model mappings
            def deregister_submodels(set)
                if !super
                    return
                end

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
                true
            end

            # Checks whether a syskit model exists for the given orogen model
            def has_model_for?(orogen_model)
                !!orogen_model_to_syskit_model[orogen_model]
            end

            # Finds the Syskit model that represents an oroGen model with that
            # name
            def find_model_from_orogen_name(name)
                orogen_model_to_syskit_model.each do |orogen_model, syskit_model|
                    if orogen_model.name == name
                        return syskit_model
                    end
                end
                nil
            end

            # Returns the syskit model for the given oroGen model
            #
            # @raise ArgumentError if no syskit model exists 
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
                    # Verify that there is not already something registered with
                    # that name
                    begin
                        constant(orogen_model.name.camelcase(:upper))
                        warn "there is already a constant with the name #{orogen_model.name.camelcase(:upper)}, I am not registering the model for #{orogen_model.name} there"
                    rescue NameError
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
                end

                klass
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
                if options[:name]
                    model.name = options[:name]
                end
                Syskit::TaskContext.orogen_model_to_syskit_model[model.orogen_model] = model
                if block
                    evaluation = DataServiceModel::BlockInstanciator.new(model)
                    evaluation.instance_eval(&block)
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

        end
    end
end

