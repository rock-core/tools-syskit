# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # Extension to the logger's task model for logging configuration
        #
        # It is automatically included in Engine#configure_logging
        module LoggerConfigurationSupport
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :logged_ports

            # True if this logger is its deployment's default logger
            #
            # In this case, it will set itself up using the deployment's logging
            # configuration
            attr_predicate :default_logger?, true

            def initialize(**arguments)
                super
                @logged_ports = Set.new
            end

            def start_only_when_connected?
                false
            end

            # Wrapper on top of the createLoggingPort operation
            #
            # @param [String] sink_port_name the desired port name on the logger
            # @param [TaskContext] the task context that is being logged
            # @param [OutputPort] the port that is being logged
            def create_logging_port(sink_port_name, logged_task, logged_port)
                logged_port_type = logged_port.model.orocos_type_name
                return if logged_ports.include?([sink_port_name, logged_port_type])

                metadata = Hash[
                    "rock_task_model" => logged_task.concrete_model.orogen_model.name,
                    "rock_task_name" => logged_task.orocos_name,
                    "rock_task_object_name" => logged_port.name,
                    "rock_stream_type" => "port"]
                metadata = metadata.map do |k, v|
                    Hash["key" => k, "value" => v]
                end

                @create_port ||= operation("createLoggingPort")
                unless @create_port.callop(sink_port_name, logged_port_type, metadata)
                    # Look whether a port with that name and type already
                    # exists. If it is the case, it means somebody else already
                    # created it and we're fine- Otherwise, raise an error
                    begin
                        port = orocos_task.port(sink_port_name)
                        logger_port_type_m = loader.intermediate_type_for(logged_port_type)
                        if port.orocos_type_name != logged_port_type && port.orocos_type_name != logger_port_type_m.name
                            raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}: a port of same name but of type #{port.model.orocos_type_name} exists"
                        end
                    rescue Runkit::NotFound
                        raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}"
                    end
                end
                logged_ports << [sink_port_name, logged_port_type]
            end

            def configure
                super

                each_concrete_input_connection do |source_task, source_port_name, sink_port_name, policy|
                    source_port = source_task.find_output_port(source_port_name)
                    create_logging_port(sink_port_name, source_task, source_port)
                end
            end

            def self.logger_dynamic_port_of(task_model)
                ports = task_model.orogen_model.each_dynamic_input_port
                                  .find_all { |p| !p.type }
                if ports.size > 1
                    raise InternalError,
                          "valid logger task contexts should have only one catch-all "\
                          "dynamic input port, #{task_model} got #{ports.size}"
                elsif ports.empty?
                    raise InternalError,
                          "valid logger task contexts should have one catch-all "\
                          "dynamic input port, and #{task_model} has none"
                end

                ports.first
            end

            # Configures each running deployment's logger, based on the
            # information in +port_dynamics+
            #
            # The "configuration" means that we create the necessary connections
            # between each component's port and the logger
            def self.add_logging_to_network(engine, work_plan)
                return unless engine.dataflow_dynamics

                fallback_policy = Hash[
                    type: :buffer,
                    size: Syskit.conf.logs.default_logging_buffer_size
                ]

                required_loggers = []
                engine.deployment_tasks.each do |deployment|
                    next unless deployment.plan

                    required_logging_ports = []
                    required_connections   = []
                    deployment.each_executed_task do |t|
                        if t.finishing? || t.finished?
                            next
                        elsif t.fullfills?(LoggerService)
                            next
                        elsif !engine.deployed_tasks.include?(t)
                            next
                        end

                        connections = {}
                        t.each_output_port do |p|
                            next unless deployment.log_port?(p)

                            log_port_name = "#{t.orocos_name}.#{p.name}"
                            connections[[p.name, log_port_name]] = Hash[fallback_policy: fallback_policy]
                            required_logging_ports << [log_port_name, t, p]
                        end
                        required_connections << [t, connections]
                    end

                    unless (logger_task = deployment.logger_task)
                        warn "deployment #{deployment.process_name} has no usable "\
                             "logger (default logger name would be "\
                             "#{deployment.process_name}_Logger)"
                        next
                    end
                    logger_task = work_plan[deployment.logger_task]

                    # Disconnect current log connections, we're going to
                    # reestablish the ones we want later on. We leave other
                    # connections as-is
                    dataflow = work_plan.task_relation_graph_for(Flows::DataFlow)
                    deployment.each_executed_task do |t|
                        if engine.deployed_tasks.include?(t)
                            dataflow.remove_relation(t, logger_task)
                        end
                    end

                    next if required_logging_ports.empty?

                    required_loggers << logger_task

                    # Make sure that the tasks are started after the logger was
                    # started
                    deployment.each_executed_task do |t|
                        if t.pending? && t != logger_task
                            t.should_start_after logger_task.start_event
                        end
                    end

                    if logger_task.setup?
                        # The logger task is already configured. Add the ports
                        # manually
                        #
                        # Otherwise, Logger#configure will take care of it for
                        # us
                        required_logging_ports.each do |port_name, logged_task, logged_port|
                            logger_task.create_logging_port(port_name, logged_task, logged_port)
                        end
                    end
                    required_connections.each do |task, connections|
                        connections =
                            connections
                            .each_with_object({}) do |(outin_port_names, policy), h|
                                in_port = logger_task.model.find_input_port(
                                    outin_port_names[1]
                                )

                                unless in_port
                                    out_port = task.model.find_output_port(
                                        outin_port_names[0]
                                    )
                                    logger_task.instanciate_dynamic_input_port(
                                        outin_port_names[1], out_port.orogen_model.type,
                                        logger_dynamic_port_of(logger_task.model)
                                    )
                                end

                                h[outin_port_names] =
                                    engine.dataflow_dynamics.policy_for(
                                        task, *outin_port_names, logger_task, policy
                                    )
                            end

                        task.connect_ports(logger_task, connections)
                    end
                end

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                required_loggers.each do |task|
                    task.arguments[:conf] = ["default"] unless task.arguments[:conf]
                    work_plan.add_permanent_task(task)
                end
            end
        end
        Engine.register_deployment_postprocessing(
            &LoggerConfigurationSupport.method(:add_logging_to_network)
        )
    end
end
