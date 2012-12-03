module Syskit
    module Models
        module Deployment
            include Models::Base

            # [Models::Deployment] Returns the parent model for this class, or
            # nil if it is the root model
            def supermodel
                if superclass.respond_to?(:register_submodel)
                    return superclass
                end
            end

            # [Orocos::Generation::Deployment] the deployment model
            attr_accessor :orogen_model

            # Returns the name of this particular deployment instance
            def deployment_name
                orogen_model.name
            end

            def instanciate(engine, arguments = Hash.new)
                new(arguments)
            end

            # Creates a new deployment model
            #
            # @option options [Orocos::Spec::Deployment] orogen_model the oroGen
            #   model for this deployment
            # @option options [String] name the model name, for anonymous model.
            #   It is usually not necessary to provide it.
            # @return [Deployment] the deployment class, as a subclass of
            #   Deployment
            def new_submodel(options = Hash.new)
                klass = Class.new(self)
                options = Kernel.validate_options options, :name, :orogen_model
                if name = options[:name]
                    klass.name = name
                end

                klass.orogen_model = options[:orogen_model] ||
                    Orocos::Spec::Deployment.new(Orocos.master_project, options[:name])
                register_submodel(klass)
                klass
            end

            # Creates a subclass of Deployment that represents the given
            # deployment
            #
            # @param [Orocos::Spec::Deployment] orogen_model the oroGen
            #   deployment model
            #
            # @option options [Boolean] register (false) if true, and if the
            #   deployment model has a name, the resulting syskit model is
            #   registered as a constant in the ::Deployments namespace. The
            #   constant's name is the camelized orogen model name.
            #
            # @return [Models::Deployment] the deployment model
            def define_from_orogen(orogen_model, options = Hash.new)
                options = Kernel.validate_options options, :register => false
                model = new_submodel(:orogen_model => orogen_model)
                if options[:register] && orogen_model.name
                    Deployments.const_set(orogen_model.name.camelcase(:upper), model)
                end
                model
            end

            # An array of Orocos::Generation::TaskDeployment instances that
            # represent the tasks available in this deployment. Associated plan
            # objects can be instanciated with #task
            def tasks
                orogen_model.task_activities
            end

            def each_orogen_deployed_task_context_model(&block)
                orogen_model.task_activities.each(&block)
            end
        end
    end
end
