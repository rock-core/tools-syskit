# frozen_string_literal: true

require "orocos/ruby_tasks/process"

module Syskit
    module RobyApp
        # A class API-compatible with {Syskit::RobyApp::RemoteProcesses::Client} but that
        # handle components started externally to syskit
        class UnmanagedTasksManager
            # Exception raised if one attempts to do name mappings in an
            # unmanaged process server
            class NameMappingsForbidden < ArgumentError; end

            # Fake status class
            class Status
                def initialize(exit_code: nil, signal: nil)
                    @exit_code = exit_code
                    @signal = signal
                end

                def stopped?
                    false
                end

                def exited?
                    !@exit_code.nil?
                end

                def exitstatus
                    @exit_code
                end

                def signaled?
                    !@signal.nil?
                end

                def termsig
                    @signal
                end

                def stopsig; end

                def success?
                    exitstatus == 0
                end
            end

            # The set of processes started so far
            #
            # @return [Hash<String,UnmanagedProcess>] mapping from process name
            #   to the process object
            attr_reader :processes

            # The name service that should be used to resolve the tasks
            #
            # @return [#get]
            attr_reader :name_service

            # The OroGen loader
            attr_reader :loader

            def initialize(loader: Roby.app.default_loader,
                name_service: Orocos::CORBA.name_service)
                @loader = loader
                @processes = {}
                @name_service = name_service
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
            def start(name, deployment_name = name, name_mappings = {}, prefix: nil, **options)
                model = if deployment_name.respond_to?(:to_str)
                            loader.deployment_model_from_name(deployment_name)
                        else deployment_name
                        end

                if processes[name]
                    raise ArgumentError, "#{name} is already started in #{self}"
                end

                prefix_mappings = Orocos::ProcessBase.resolve_prefix(model, prefix)
                name_mappings = prefix_mappings.merge(name_mappings)
                name_mappings.each do |from, to|
                    if from != to
                        raise NameMappingsForbidden, "cannot do name mapping in unmanaged processes"
                    end
                end

                process = UnmanagedProcess.new(self, name, model)
                process.spawn
                processes[name] = process
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
            def wait_termination(timeout = nil)
                # Verify that the monitor threads are in a good state, and
                # gather the ones that are actually dead
                dead_processes = Set.new
                processes.delete_if do |_, process|
                    begin
                        process.verify_threads_state
                    rescue Exception => e
                        process.fatal "assuming #{process} died because the background thread died with"
                        Roby.log_exception(e, process, :fatal)
                        dead_processes << process
                    end

                    if process.dead?
                        dead_processes << process
                    end
                    dead_processes.include?(process)
                end
                dead_processes
            end

            # Requests to stop the given deployment
            #
            # The call does not block until the process has quit. You will have to
            # call #wait_termination to wait for the process end.
            def stop(world_name)
                if w = processes[world_name]
                    w.kill
                end
            end
        end
    end
end
