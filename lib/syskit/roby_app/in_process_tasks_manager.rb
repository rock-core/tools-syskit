# frozen_string_literal: true

module Syskit
    module RobyApp
        # A class API-compatible with {Syskit::RobyApp::RemoteProcesses::Client} but that
        # creates components in-process
        class InProcessTasksManager
            # Exception raised if one attempts to do name mappings in an
            # unmanaged process server
            class NameMappingsForbidden < ArgumentError; end

            # Fake status class
            class Status
                def stopped?
                    false
                end

                def exited?
                    false
                end

                def exitstatus; end

                def signaled?
                    false
                end

                def termsig; end

                def stopsig; end

                def success?
                    true
                end
            end

            # The set of processes started so far
            #
            # @return [Hash<String,UnmanagedProcess>] mapping from process name
            #   to the process object
            attr_reader :processes

            # The model loader
            #
            # @return [OroGen::Loaders::PkgConfig]
            attr_reader :loader

            def initialize(component_loader: Roby.app.syskit_component_loader)
                @component_loader = component_loader
                @loader = component_loader.pkgconfig_loader
                @processes = {}
                @deployments = {}
            end

            def disconnect; end

            # Register a new deployment model on this server.
            #
            # If name mappings are needed, they must have been done in the
            # model. {#start} does not support name mappings
            def register_deployment_model(model)
                loader.register_deployment_model(model)
            end

            # Start a registered deployment
            #
            # @param [String] name the desired process name
            # @param [String,OroGen::Spec::Deployment] deployment_name either
            #   the name of a deployment model on {#loader}, or the deployment
            #   model itself
            # @param [Hash] name_mappings name mappings. This is provided for
            #   compatibility with the process server API, but should always be
            #   empty
            # @param [String] prefix a prefix to be added to all tasks in the
            #   deployment.  This is provided for
            #   compatibility with the process server API, but should always be
            #   nil
            # @param [Hash] options additional spawn options. This is provided
            #   for compatibility with the process server API, but is ignored
            # @return [UnmanagedProcess]
            def start(name, deployment_name = name, name_mappings = {}, prefix: nil, **_)
                if processes[name]
                    raise ArgumentError, "#{name} is already started in #{self}"
                end

                model = resolve_deployment_model(deployment_name)
                process = InProcessDeployment.new(self, name, model)
                apply_name_mappings(process, model, prefix, name_mappings)
                process.spawn
                processes[name] = process
            end

            def resolve_deployment_model(model_or_name)
                return model_or_name unless model_or_name.respond_to?(:to_str)

                loader.deployment_model_from_name(model_or_name)
            end

            def apply_name_mappings(process, model, prefix, name_mappings)
                prefix_mappings = Orocos::ProcessBase.resolve_prefix(model, prefix)
                name_mappings = prefix_mappings.merge(name_mappings)
                name_mappings.each { process.map_name(_1, _2) }
            end

            # Requests that the process server moves the log directory at +log_dir+
            # to +results_dir+
            def save_log_dir(log_dir, results_dir); end

            # Creates a new log dir, and save the given time tag in it (used later
            # on by save_log_dir)
            def create_log_dir(log_dir, time_tag, metadata = {}); end

            # Waits for processes to terminate. +timeout+ is the number of
            # milliseconds we should wait. If set to nil, the call will block until
            # a process terminates
            #
            # Returns a hash that maps deployment names to the Status
            # object that represents their exit status.
            def wait_termination(_timeout = nil)
                dead_processes = {}
                processes.delete_if do |_, process|
                    next unless process.dead?

                    dead_processes[process] = Status.new
                    true
                end
                dead_processes
            end

            def wait_running(*process_names)
                result = {}
                process_names.each do |name|
                    if (p = processes[name])
                        result[name] = { iors: p.wait_running(0) }
                    else
                        result[name] =
                            { error: "#{name} was not found of the processes list" }
                    end
                end
                result
            end

            # Requests to stop the given deployment
            #
            # The call does not block until the process has quit. You will have to
            # call #wait_termination to wait for the process end.
            def stop(process_name)
                processes[process_name]&.kill
            end

            DEFAULT_LOGGER_NAME = "syskit_in_process_logger"

            def default_logger_task(plan, app: Roby.app)
                self.class.default_logger_task(plan, app: app)
            end

            def self.find_default_logger_task(plan, app: Roby.app)
                return unless (logger_m = app.syskit_logger_m)

                plan.find_tasks(logger_m).permanent.first
            end

            # The logger task
            def self.default_logger_task(plan, app: Roby.app)
                return unless (deployment = app.syskit_in_process_logger_deployment)

                if (t = find_default_logger_task(plan))
                    return t
                end

                plan.add_permanent_task(deployment_t = deployment.new)
                plan.add_permanent_task(logger_t = deployment_t.task(DEFAULT_LOGGER_NAME))
                logger_t.default_logger = true if logger_t.respond_to?(:default_logger=)
                logger_t
            end

            def self.register_default_logger_deployment(app, conf: Syskit.conf)
                return unless (logger_m = app.syskit_logger_m)

                d = conf.use_in_process_tasks(logger_m => DEFAULT_LOGGER_NAME).first
                app.syskit_in_process_logger_deployment = d
            end

            def self.deregister_default_logger_deployment(app, conf: Syskit.conf)
                return unless (d = app.syskit_in_process_logger_deployment)

                conf.deregister_configured_deployment(d)
                app.syskit_in_process_logger_deployment = nil
            end
        end
    end
end
