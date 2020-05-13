# frozen_string_literal: true

# Module where all the OroGen task context models get registered
module OroGen
    extend Syskit::OroGenNamespace
    Deployments = Syskit::OroGenNamespace::DeploymentNamespace.new

    self.syskit_model_constant_registration = true
end

module Syskit
    # Extend an auto-generated with custom code
    #
    # This is used mainly for Syskit models generated from oroGen models, in
    # extension files within models/orogen/:
    #
    #     Syskit.extend_model OroGen.test.Task do
    #       def configure
    #         super
    #         ...
    #       end
    #     end
    #
    def self.extend_model(model, &block)
        model.class_eval(&block)
    end

    module Models
        # This module contains the model-level API for the task context models
        #
        # It is used to extend every subclass of Syskit::TaskContext
        module TaskContext
            include Models::Component
            include Models::PortAccess
            include Models::OrogenBase

            # @return [String] path to the extension file that got loaded to
            #   extend this model
            attr_accessor :extension_file

            # Checks if a given component implementation needs to be stubbed
            def needs_stub?(component)
                super || component.orocos_task.kind_of?(Orocos::RubyTasks::StubTaskContext)
            end

            def clear_registration_as_constant
                super

                if name = self.name
                    return if name !~ /^OroGen::/

                    name = name.gsub(/^OroGen::/, "")
                    begin
                        if constant("::#{name}") == self
                            spacename = self.spacename.gsub(/^OroGen::/, "")
                            constant("::#{spacename}").send(:remove_const, basename)
                        end
                    rescue NameError
                        false
                    end
                end
            end

            # Generates a hash of oroGen-level state names to Roby-level event
            # names
            #
            # @return [{Symbol=>Symbol}]
            def make_state_events
                with_superclass = !supermodel || !supermodel.respond_to?(:orogen_model) || (supermodel.orogen_model != orogen_model.superclass)
                orogen_model.each_state(with_superclass: with_superclass) do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    if type == :toplevel
                        event event_name,
                              terminal: %w[EXCEPTION FATAL_ERROR].include?(name)
                    else
                        event event_name,
                              terminal: %i[exception fatal_error].include?(type)
                        if type == :fatal
                            forward event_name => :fatal_error
                        elsif type == :exception
                            forward event_name => :exception
                        elsif type == :error
                            forward event_name => :runtime_error
                        end
                    end

                    state_events[name.to_sym] = event_name
                end
            end

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def define_from_orogen(orogen_model, register: false)
                if model = find_model_by_orogen(orogen_model) # already defined, probably because of dependencies
                    return model
                end

                superclass = orogen_model.superclass
                supermodel =
                    if superclass # we are defining a root model
                        find_model_by_orogen(superclass) ||
                            define_from_orogen(superclass, register: register)
                    else
                        self
                    end
                klass = supermodel.new_submodel(orogen_model: orogen_model)

                klass.register_model if register && orogen_model.name
                klass
            end

            def register_model
                OroGen.syskit_model_toplevel_constant_registration =
                    Roby.app.backward_compatible_naming?
                self.name = OroGen.register_syskit_model(self)
            end

            # This component's oroGen model
            attr_accessor :orogen_model

            # Set this class up to represent an oroGen root model
            def root_model
                @orogen_model = Models.create_orogen_task_context_model
                make_state_events
            end

            # A state_name => event_name mapping that maps the component's
            # state names to the event names that should be emitted when it
            # enters a new state.
            inherited_attribute(:state_event, :state_events, map: true) { {} }

            # Create a new TaskContext model
            #
            # @option options [String] name (nil) forcefully set a name for the model.
            #   This is only useful for "anonymous" models, i.e. models that are
            #   never assigned in the Ruby constant hierarchy
            # @option options [Orocos::Spec::TaskContext, Orocos::ROS::Spec::Node] orogen_model (nil) the
            #   oroGen model that should be used. If not given, an empty model
            #   is created, possibly with the name given to the method as well.
            def new_submodel(**options, &block)
                super
            end

            def apply_block(&block)
                evaluation = DataServiceModel::BlockInstanciator.new(self)
                evaluation.instance_eval(&block)
            end

            # Sets up self on the basis of {#supermodel}
            #
            # @param [String] name an optional name for this submodel
            # @return [void]
            def setup_submodel(submodel,
                orogen_model: nil,
                orogen_model_name: submodel.name,
                **options)

                unless orogen_model
                    orogen_model = self.orogen_model.class.new(
                        Roby.app.default_orogen_project, orogen_model_name,
                        subclasses: self.orogen_model
                    )
                    orogen_model.extended_state_support
                end
                submodel.orogen_model = orogen_model
                super
                submodel.make_state_events
            end

            def worstcase_processing_time(value)
                orogen_model.worstcase_processing_time(value)
            end

            def each_event_port(&block)
                orogen_model.each_event_port(&block)
            end

            # Override this model's default configuration manager
            #
            # @see configuration_manager
            attr_writer :configuration_manager

            # Returns the configuration management object for this task model
            #
            # @return [TaskConfigurationManager]
            def configuration_manager
                unless @configuration_manager
                    if !concrete_model?
                        manager = concrete_model.configuration_manager
                    else
                        manager = TaskConfigurationManager.new(Roby.app, self)
                        manager.reload
                    end
                    @configuration_manager = manager
                end
                @configuration_manager
            end

            # Merge the service model into self
            #
            # This is mainly used during dynamic service instantiation, to
            # update the underlying ports and trigger model based on the
            # service's orogen model
            def merge_service_model(service_model, port_mappings)
                Syskit::Models.merge_orogen_task_context_models(
                    orogen_model, [service_model.orogen_model], port_mappings
                )
            end

            def to_deployment_group(name, **options)
                group = Models::DeploymentGroup.new
                group.use_deployment(self => name, **options)
                group
            end

            # Return the instance requirement object that runs this task
            # model with the given name
            def deployed_as(name, **options)
                to_instance_requirements.deployed_as(name, **options)
            end

            # Return the instance requirement object that will hook onto
            # an otherwise started component of the given name
            # model with the given name
            def deployed_as_unmanaged(name, **options)
                to_instance_requirements.deployed_as_unmanaged(name, **options)
            end
        end
    end
end
