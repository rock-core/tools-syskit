# frozen_string_literal: true

module Syskit
    module RobyApp
        module RubyTasks
            # This is a drop-in replacement for ProcessClient. It creates Ruby tasks in
            # the local process, based on the deployment models
            class ProcessManager
                # @api private
                #
                # Status class equivalent to Ruby's own Process::Status to report
                # "process" end
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

                attr_reader :deployments
                attr_reader :loader
                attr_reader :terminated_deployments

                # The task context class that should be used on the client side
                #
                # Defaults to {TaskContext}, another option is {StubTaskContext}
                #
                # @return [Class]
                attr_reader :task_context_class

                def initialize(
                    loader = Orocos.default_loader,
                    task_context_class: Orocos::RubyTasks::TaskContext
                )
                    @loader = loader
                    @deployments = {}
                    @terminated_deployments = {}
                    @task_context_class = task_context_class
                end

                def disconnect; end

                def register_deployment_model(model)
                    loader.register_deployment_model(model)
                end

                def start( # rubocop:disable Metrics/ParameterLists
                    name, deployment_name, name_mappings,
                    prefix: nil, task_context_class: self.task_context_class,
                    register_on_name_server: true, **_
                )
                    model = if deployment_name.respond_to?(:to_str)
                                loader.deployment_model_from_name(deployment_name)
                            else deployment_name
                            end
                    if deployments[name]
                        raise ArgumentError, "#{name} is already started in #{self}"
                    end

                    prefix_mappings = Orocos::ProcessBase.resolve_prefix(model, prefix)
                    name_mappings = prefix_mappings.merge(name_mappings)

                    ruby_deployment = Process.new(
                        self, name, model,
                        task_context_class: task_context_class
                    )
                    ruby_deployment.name_mappings = name_mappings
                    ruby_deployment.spawn(
                        register_on_name_server: register_on_name_server
                    )
                    deployments[name] = ruby_deployment
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
                    result = terminated_deployments
                    @terminated_deployments = {}
                    result
                end

                def wait_running(*process_names)
                    process_ior_mappings = {}
                    process_names.each do |name|
                        if deployments[name]&.resolve_all_tasks
                            process_ior_mappings[name] = {
                                iors: deployments[name].wait_running
                            }
                        else
                            process_ior_mappings[name] = {
                                error: "#{name} is not a valid process in the deployment"
                            }
                        end
                    end
                    process_ior_mappings
                end

                # Requests to stop the given deployment
                #
                # The call does not block until the process has quit. You will have to
                # call #wait_termination to wait for the process end.
                def stop(deployment_name)
                    deployments[deployment_name]&.kill
                end

                def dead_deployment(deployment_name, status = Status.new(exit_code: 0))
                    return unless (deployment = deployments.delete(deployment_name))

                    terminated_deployments[deployment] = status
                end

                def default_logger_task(plan, app: Roby.app)
                    InProcessTasksManager.default_logger_task(plan, app: app)
                end
            end
        end
    end
end
