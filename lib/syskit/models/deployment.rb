module Syskit
    module Models
        module Deployment
            # [Orocos::Generation::Deployment] the deployment model
            attr_reader :orogen_model

            end

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
                klass
            end

            # Creates a subclass of Deployment that represents the deployment
            # specified by +deployment_spec+.
            def define_from_orogen(deployment_spec)
                model = new_submodel(:orogen_model => deployment_spec)
                Deployments.const_set(deployment_spec.name.camelcase(:upper), model)
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
