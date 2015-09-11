module Syskit
    class RubyTaskContext < Syskit::TaskContext
        def self.input_port(*args, &block)
            orogen_model.input_port(*args, &block)
        end

        def self.output_port(*args, &block)
            orogen_model.output_port(*args, &block)
        end

        def self.deployment_model(task_name)
            orogen_model = self.orogen_model
            @deployment_model ||= Deployment.new_submodel(name: "Deployment::RubyTasks::#{name}") do
                task task_name, orogen_model
            end
        end
    end
end

