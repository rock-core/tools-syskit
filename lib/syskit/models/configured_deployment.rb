module Syskit
    module Models
        # Representation of a deployment that is configured with name mappings
        # and spawn options
        class ConfiguredDeployment
            attr_reader :process_name
            attr_reader :model
            attr_reader :spawn_options
            attr_reader :name_mappings

            def initialize(model, name_mappings = Hash.new, process_name = model.name, spawn_options = Hash.new)
                @model, @name_mappings, @process_name, @spawn_options = model, name_mappings, process_name, spawn_options
            end

            def orogen_model
                if @orogen_model
                    return @orogen_model
                end

                @orogen_model = model.orogen_model.dup
                orogen_model.task_activities.map! do |activity|
                    activity = activity.dup
                    activity.name = name_mappings[activity.name] || activity.name
                    activity
                end
                @orogen_model
            end

            def each_orogen_deployed_task_context_model
                model.each_orogen_deployed_task_context_model do |deployed_task|
                    task = deployed_task.dup
                    task.name = name_mappings[task.name] || task.name
                    yield(task)
                end
            end

            def new(options = Hash.new)
                options = options.merge(
                    :process_name => process_name,
                    :name_mappings => name_mappings,
                    :spawn_options => spawn_options)
                options.delete(:working_directory)
                options.delete(:output)
                options.delete(:wait)
                model.new(options)
            end
        end
    end
end

