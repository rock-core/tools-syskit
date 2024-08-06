# frozen_string_literal: true

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
            # @return [Array] the tasks related to this deployment supposed to be set as
            #   read only
            attr_reader :read_only
            # @return [String] the name of the logger to override the default logger name.
            attr_reader :logger_name

            # rubocop: disable Metrics/ParameterLists
            def initialize(
                process_server_name, model, name_mappings = {},
                process_name = model.name, spawn_options = {}, read_only: false,
                logger_name: nil, **spawn_options_kw
            )
                default_mappings =
                    model
                    .each_deployed_task_model
                    .each_with_object({}) do |(deployed_task_name, _), result|
                        result[deployed_task_name] = deployed_task_name
                    end

                @process_server_name = process_server_name
                @model               = model
                @name_mappings       = default_mappings.merge(name_mappings)
                @process_name        = process_name
                @spawn_options       = spawn_options.merge(spawn_options_kw)
                @read_only           = resolve_read_only(read_only, @name_mappings)
                @logger_name         = logger_name
            end
            # rubocop: enable Metrics/ParameterLists

            # @api private
            #
            # Resolves the read_only argument into an Array of task names to be set as
            # read_only.
            #
            # @return [Array<String>]
            def resolve_read_only(read_only, mappings)
                non_logger_names = mappings.values.reject { |name| /_Logger$/ === name }
                return non_logger_names if read_only == true
                return [] unless read_only

                read_only = [read_only] unless read_only.kind_of?(Array)
                selection = non_logger_names.select do |task_name|
                    read_only.any? { |task_name_pattern| task_name_pattern === task_name }
                end
                if selection.empty? && !read_only.empty?
                    raise ArgumentError,
                          "#{read_only} is not a valid deployed task name or pattern. "\
                          "The valid deployed task names are #{non_logger_names}."
                end
                selection
            end

            # @api private
            #
            # Filters out options that are part of the spawn options but not of
            # the command-line generation options
            def filter_command_line_options(
                oro_logfile: nil, output: nil,
                **command_line_options
            )
                command_line_options
            end

            # Returns the command line information needed to start this
            # deployment on the same machine than Syskit
            def command_line(loader: Roby.app.default_pkgconfig_loader, **options)
                model.command_line(
                    process_name, name_mappings,
                    loader: loader,
                    **filter_command_line_options(**options)
                )
            end

            # The oroGen model object that represents this configured deployment
            #
            # It differs from model.orogen_model in that the {#name_mappings}
            # are applied
            #
            # @return [OroGen::Spec::Deployment]
            def orogen_model
                return @orogen_model if @orogen_model

                @orogen_model = model.orogen_model.dup
                orogen_model.task_activities.map! do |activity|
                    activity = activity.dup
                    activity.name = name_mappings[activity.name] || activity.name
                    activity
                end
                @orogen_model
            end

            # Enumerate the tasks that are deployed by this configured
            # deployment
            #
            # Unlike {#each_orogen_deployed_task_context_model}, it enumerates
            # the Syskit task context model
            #
            # @yieldparam [String] name the task's mapped name, that is the name
            #     the task will have at runtime
            # @yieldparam [Models::TaskCOntext] the task model
            def each_deployed_task_model
                return enum_for(__method__) unless block_given?

                model.each_deployed_task_model do |name, model|
                    yield(name_mappings[name], model)
                end
            end

            # Enumerate the oroGen specification for the deployed tasks
            #
            # @yieldparam [OroGen::Spec::TaskDeployment]
            def each_orogen_deployed_task_context_model
                return enum_for(__method__) unless block_given?

                model.each_orogen_deployed_task_context_model do |deployed_task|
                    task = deployed_task.dup
                    task.name = name_mappings[task.name] || task.name
                    yield(task)
                end
            end

            # Create a new deployment task that can represent self in a plan
            #
            # @return [Syskit::Deployment] a new, properly configured, instance
            #   of {#model}. Usually a {Syskit::Deployment}
            def new(**options)
                options = options.merge(
                    process_name: process_name,
                    name_mappings: name_mappings,
                    spawn_options: spawn_options,
                    on: process_server_name,
                    read_only: read_only,
                    logger_name: logger_name
                )
                options.delete(:working_directory)
                options.delete(:output)
                options.delete(:wait)
                model.new(**options)
            end

            # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
            def ==(other)
                return unless other.kind_of?(ConfiguredDeployment)

                process_server_name == other.process_server_name &&
                    process_name == other.process_name &&
                    model == other.model &&
                    spawn_options == other.spawn_options &&
                    name_mappings == other.name_mappings &&
                    read_only == other.read_only &&
                    logger_name == other.logger_name
            end
            # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize

            def hash
                [process_name, model].hash
            end

            def eql?(other)
                self == other
            end

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
