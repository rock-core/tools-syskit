# frozen_string_literal: true

module Syskit
    module Telemetry
        module UI
            class Poller
                # A job that is used to scope the data updates
                #
                # @see select_current_job reset_current_job
                attr_reader :current_job

                # List of orocos task names that are involved in the current job
                attr_reader :current_job_task_names

                def initialize(syskit:)
                    @name_service = NameService.new
                    @syskit = syskit
                    @call_guards = {}
                end

                def poll
                    if syskit.connected?
                        begin
                            update_current_deployments
                            update_current_job_task_names if current_job
                        rescue Roby::Interface::ComError # rubocop:disable Lint/SuppressedException
                        end
                    else
                        reset_current_deployments
                        reset_current_job
                        reset_name_service
                    end

                    syskit.poll
                end

                def cycle_start_time
                    @syskit.cycle_start_time
                end

                def cycle_index
                    @syskit.cycle_index
                end

                def orocos_task_names
                    @name_service.names
                end

                def selected_orocos_task_names
                    names = @name_service.names
                    names &= @current_job_task_names if @current_job
                    names
                end

                def select_current_job(job)
                    @current_job = job
                    @current_job_names = []
                end

                def reset_current_job
                    @current_job = nil
                    @current_job_names = []
                end

                def update_current_deployments
                    polling_call ["syskit"], "deployments" do |deployments|
                        @current_deployments = deployments
                        update_name_service(deployments)
                    end
                end

                def reset_current_deployments
                    @current_deployments = []
                end

                def update_current_job_task_names
                    polling_call [], "tasks_of_job", @current_job.job_id do |tasks|
                        @current_job_task_names =
                            tasks
                            .map { _1.arguments[:orocos_name] }
                            .compact
                    end
                end

                def update_name_service(deployments)
                    # Now remove all tasks that are not in deployments
                    existing = @name_service.names

                    deployments.each do |d|
                        d.deployed_tasks.each do |deployed_task|
                            task_name = deployed_task.name
                            if existing.include?(task_name)
                                existing.delete(task_name)
                                next if deployed_task.ior == @name_service.ior(task_name)
                            end

                            existing.delete(task_name)
                            task = Orocos::TaskContext.new(
                                deployed_task.ior,
                                name: task_name,
                                model: orogen_model_from_name(
                                    deployed_task.orogen_model_name
                                )
                            )

                            async_task = Orocos::Async::CORBA::TaskContext.new(use: task)
                            @name_service.register(async_task, name: task_name)
                        end
                    end

                    existing.each { @name_service.deregister(_1) }
                    @name_service.names
                end

                def orogen_model_from_name(name)
                    @orogen_models[name] ||=
                        Orocos.default_loader.task_model_from_name(name)
                rescue OroGen::NotFound
                    Orocos.warn(
                        "#{name} is a task context of class #{name}, but I cannot "\
                        "find the description for it, falling back"
                    )
                    @orogen_models[name] ||=
                        Orocos.create_orogen_task_context_model(name)
                end

                def reset_name_service
                    all = @name_service.names.dup
                    all.each { @name_service.deregister(_1) }
                end

                def polling_call(path, method_name, *args)
                    key = [path, method_name, args]
                    if @call_guards.key?(key)
                        return unless @call_guards[key]
                    end

                    @call_guards[key] = false
                    syskit.async_call(path, method_name, *args) do |error, ret|
                        @call_guards[key] = true
                        if error
                            report_app_error(error)
                        else
                            yield(ret)
                        end
                    end
                end

                def async_call(path, method_name, *args)
                    syskit.async_call(path, method_name, *args) do |error, ret|
                        if error
                            report_app_error(error)
                        else
                            yield(ret)
                        end
                    end
                end
            end
        end
    end
end
