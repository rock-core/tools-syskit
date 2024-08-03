# frozen_string_literal: true

require "orocos/ruby_tasks/process"

module Syskit
    module ProcessManagers
        module Unmanaged
            # Management of deployments that are started externally
            #
            # Unmanaged processes are picking up tasks through their name
            # (that is, through the CORBA naming service) and make them available
            # to the Syskit instance. At runtime, they monitor whether the task
            # can still be reached and abort the process if not
            class Manager
                # Exception raised if one attempts to do name mappings in an
                # unmanaged process server
                class NameMappingsForbidden < ArgumentError; end

                # The set of processes started so far
                #
                # @return [Hash<String,Process>] mapping from process name
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
                # @return [Process]
                def start(
                    name, deployment_name = name, name_mappings = {},
                    prefix: nil, **
                )
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
                            raise NameMappingsForbidden,
                                  "cannot do name mapping in unmanaged processes"
                        end
                    end

                    process = Process.new(self, name, model)
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
                def wait_termination(_timeout = nil)
                    # Verify that the monitor threads are in a good state, and
                    # gather the ones that are actually dead
                    dead_processes = {}
                    processes.delete_if do |_, process|
                        next unless process.dead?

                        begin
                            process.verify_threads_state
                            dead_processes[process] = Status.new(true)
                        rescue Exception => e # rubocop:disable Lint/RescueException
                            process.fatal(
                                "assuming #{process} died because the background "\
                                "thread died with"
                            )
                            Roby.log_exception(e, process, :fatal)

                            dead_processes[process] = Status.new(false)
                        end

                        true
                    end
                    dead_processes
                end

                def wait_running(*process_names)
                    result = {}
                    process_names.each do |name|
                        if (p = processes[name])
                            begin
                                ior_resolution = p.wait_running(0)
                                result[name] = { iors: ior_resolution }
                            rescue Orocos::NotFound, Orocos::CORBA::ComError => e
                                result[name] = { error: e.message }
                            end
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
                def stop(world_name)
                    processes[world_name]&.kill
                end
            end
        end
    end
end
