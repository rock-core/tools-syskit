module Syskit
    class RubyTaskContext < Syskit::TaskContext
        def self.input_port(*args, &block)
            orogen_model.input_port(*args, &block)
        end

        def self.output_port(*args, &block)
            orogen_model.output_port(*args, &block)
        end

        # Create a deployment model for this RubyTaskContext
        #
        # The deployment is created with a single task named 'task'
        def self.deployment_model
            orogen_model = self.orogen_model
            @deployment_model ||= Deployment.new_submodel(name: "Deployment::RubyTasks::#{name}") do
                task 'task', orogen_model
            end
        end
    end
end

