module Syskit
    module Models
        # Representation of a deployment that is configured with name mappings
        # and spawn options
        class ConfiguredDeployment
            # @return [String] the name of the process server this deployment
            #   should run on
            attr_reader :process_server_name
            # @return [String] the process name
            attr_reader :process_name
            # @return [Model<Syskit::Deployment>] the deployment model
            attr_reader :model
            # @return [Hash] the options that should be passed at deployment
            #   startup
            attr_reader :spawn_options
            # @return [Hash] the name mappings, e.g. the mapping from a task
            #   name in {#model} to the name this task should have while running
            attr_reader :name_mappings

            def initialize(process_server_name, model, name_mappings = Hash.new, process_name = model.name, spawn_options = Hash.new)
                @process_server_name, @model, @name_mappings, @process_name, @spawn_options =
                    process_server_name, model, name_mappings, process_name, spawn_options
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

            def ==(other)
                return if !other.kind_of?(ConfiguredDeployment)
                return process_server_name == other.process_server_name &&
                    process_name == other.process_name &&
                    model == other.model &&
                    spawn_options == other.spawn_options &&
                    name_mappings == other.name_mappings
            end

            def hash
                [process_name, model].hash
            end

            def eql?(other); self == other end

            def pretty_print(pp)
                pp.text "deployment #{model.orogen_model.name} with the following tasks"
                pp.nest(2) do
                    each_orogen_deployed_task_context_model do |task|
                        pp.breakable
                        task.pretty_print(pp)
                    end
                end
            end
        end
    end
end

