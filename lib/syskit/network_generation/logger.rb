module Syskit
    module NetworkGeneration
        # Extension to the logger's task model for logging configuration
        #
        # It is automatically included in Engine#configure_logging
        module LoggerConfigurationSupport
            attr_reader :logged_ports

            # True if this logger is its deployment's default logger
            #
            # In this case, it will set itself up using the deployment's logging
            # configuration
            attr_predicate :default_logger?, true

            def initialize(arguments = Hash.new)
                super
                @logged_ports = Set.new
            end

            # Wrapper on top of the createLoggingPort operation
            #
            # @param [String] sink_port_name the desired port name on the logger
            # @param [TaskContext] the task context that is being logged
            # @param [OutputPort] the port that is being logged
            def createLoggingPort(sink_port_name, logged_task, logged_port)
                return if logged_ports.include?([sink_port_name, logged_port.type.name])

                logged_port_type = logged_port.model.orocos_type_name

                metadata = Hash[
                    'rock_task_model' => logged_task.concrete_model.orogen_model.name,
                    'rock_task_name' => logged_task.orocos_name,
                    'rock_task_object_name' => logged_port.name,
                    'rock_stream_type' => 'port']
                metadata = metadata.map do |k, v|
                    Hash['key' => k, 'value' => v]
                end

                @create_port ||= operation('createLoggingPort')
                if !@create_port.callop(sink_port_name, logged_port_type, metadata)
                    # Look whether a port with that name and type already
                    # exists. If it is the case, it means somebody else already
                    # created it and we're fine- Otherwise, raise an error
                    begin
                        port = find_input_port(sink_port_name)
                        logger_port_type_m = Orocos.master_project.intermediate_type_for(logged_port_type)
                        if port.model.orocos_type_name != logged_port_type && port.model.orocos_type_name != logger_port_type_m.name
                            raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}: a port of same name but of type #{port.model.orocos_type_name} exists"
                        end
                    rescue Orocos::NotFound
                        raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}"
                    end
                end
                logged_ports << [sink_port_name, logged_port_type]
            end

            def configure
                super

                if default_logger?
                    deployment = execution_agent
                    # Only setup the logger
                    deployment.orocos_process.setup_default_logger(
                        :log_dir => deployment.log_dir,
                        :remote => (deployment.host != 'localhost'))
                end

                each_input_connection do |source_task, source_port_name, sink_port_name, policy|
                    source_port = source_task.find_output_port(source_port_name)
                    createLoggingPort(sink_port_name, source_task, source_port)
                end
            end

            def self.logger_dynamic_port
                if @logger_dynamic_port
                    return @logger_dynamic_port
                end

                ports = Logger::Logger.orogen_model.dynamic_ports.find_all { |p| !p.type && p.kind_of?(Orocos::Spec::InputPort) }
                if ports.size > 1
                    raise InternalError, "oroGen's logger::Logger task should have only one catch-all dynamic input port"
                elsif ports.empty?
                    raise InternalError, "oroGen's logger::Logger task should have one catch-all dynamic input port, and has none"
                end
                @logger_dynamic_port = ports.first
            end

            # Configures each running deployment's logger, based on the
            # information in +port_dynamics+
            #
            # The "configuration" means that we create the necessary connections
            # between each component's port and the logger
            def self.add_logging_to_network(engine, work_plan)
                logger_model = TaskContext.find_model_from_orogen_name 'logger::Logger'
                return if !logger_model or !Syskit.conf.conf_log_enabled?
                logger_model.include LoggerConfigurationSupport

                engine.deployment_tasks.each do |deployment|
                    next if !deployment.plan

                    logger_task = nil
                    logger_task_name = "#{deployment.process_name}_Logger"

                    required_logging_ports = Array.new
                    required_connections   = Array.new
                    deployment.each_executed_task do |t|
                        if t.finishing? || t.finished?
                            next
                        end

                        if !logger_task && t.orocos_name == logger_task_name
                            logger_task = t
                            next
                        elsif t.kind_of?(logger_model)
                            next
                        end

                        connections = Hash.new

                        all_ports = []

                        t.each_output_port do |p|
                            all_ports << [p.name, p]
                        end

                        all_ports.each do |port_name, p|
                            next if !deployment.log_port?(p)

                            log_port_name = "#{t.orocos_name}.#{port_name}"
                            connections[[port_name, log_port_name]] = { :fallback_policy => { :type => :buffer, :size => Syskit.conf.default_logging_buffer_size } }
                            required_logging_ports << [log_port_name, t, p]
                        end
                        required_connections << [t, connections]
                    end
                    next if required_logging_ports.empty?

                    logger_task ||=
                        begin
                            deployment.task(logger_task_name)
                        rescue ArgumentError
                            warn "deployment #{deployment.process_name} has no logger (#{logger_task_name})"
                            next
                        end
                    logger_task.default_logger = true
                    # Make sure that the tasks are started after the logger was
                    # started
                    deployment.each_executed_task do |t|
                        if t.pending?
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
                            logger_task.createLoggingPort(port_name, logged_task, logged_port)
                        end
                    end
                    required_connections.each do |task, connections|
                        connections = connections.map_value do |(port_name, log_port_name), policy|
                            out_port = task.model.find_output_port(port_name)

                            if !logger_task.model.find_input_port(log_port_name)
                                logger_task.instanciate_dynamic_input_port(log_port_name, out_port.type, logger_dynamic_port)
                            end
                            engine.dataflow_dynamics.policy_for(task, port_name, log_port_name, logger_task, policy)
                        end

                        task.connect_ports(logger_task, connections)
                    end
                end

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                work_plan.find_local_tasks(logger_model).
                    each do |task|
                        if !task.arguments[:conf]
                            task.arguments[:conf] = ['default']
                        end
                    end

                # Mark as permanent any currently running logger
                work_plan.find_tasks(logger_model).
                    not_finished.
                    each do |t|
                        engine.add_toplevel_task(t, false, true)
                    end
            end
        end
        Engine.register_deployment_postprocessing(
            &LoggerConfigurationSupport.method(:add_logging_to_network))
    end
end


