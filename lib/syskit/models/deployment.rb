module Syskit
    module Models
        module Deployment
            # [Orocos::Generation::Deployment] the deployment model
            attr_reader :orogen_model

            def short_name
                name.gsub("Syskit::", "")
            end

            # Returns the name of this particular deployment instance
            def deployment_name
                orogen_model.name
            end

            def instanciate(engine, arguments = Hash.new)
                new(arguments)
            end

            def new_submodel(deployment_spec)
                klass = Class.new(Deployment)
                klass.instance_variable_set :@orogen_model, deployment_spec
                klass
            end

            # Creates a subclass of Deployment that represents the deployment
            # specified by +deployment_spec+.
            #
            # +deployment_spec+ is an instance of Orogen::Generation::Deployment
            def define_from_orogen(deployment_spec)
                model = new_submodel(deployment_spec)
                Deployments.const_set(deployment_spec.name.camelcase(:upper), model)
                model
            end

            # An array of Orocos::Generation::TaskDeployment instances that
            # represent the tasks available in this deployment. Associated plan
            # objects can be instanciated with #task
            def tasks
                orogen_model.task_activities
            end

            def each_deployed_task_context(&block)
                orogen_model.task_activities.each(&block)
            end
        end
    end
end
