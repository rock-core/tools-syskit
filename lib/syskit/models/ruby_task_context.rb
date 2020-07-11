# frozen_string_literal: true

module Syskit
    module Models
        module RubyTaskContext
            def input_port(*args, &block)
                orogen_model.input_port(*args, &block)
            end

            def output_port(*args, &block)
                orogen_model.output_port(*args, &block)
            end

            def to_deployment_group(name, **options)
                group = Models::DeploymentGroup.new
                group.use_ruby_tasks({ self => name }, **options)
                group
            end

            # Return the instance requirement object that runs this task
            # model with the given name
            def deployed_as(name, **options)
                to_instance_requirements.deployed_as(name, **options)
            end

            # Create a deployment model for this RubyTaskContext
            #
            # The deployment is created with a single task named 'task'
            def deployment_model
                orogen_model = self.orogen_model
                deployment_name = "Deployment::RubyTasks::#{name}"
                @deployment_model ||=
                    Syskit::Deployment.new_submodel(name: deployment_name) do
                        task "task", orogen_model
                    end
            end
        end
    end
end
