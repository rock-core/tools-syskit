# frozen_string_literal: true

module Syskit
    module Runtime
        # This method is called once at the beginning of each execution cycle to
        # update the state of Deployment tasks w.r.t. the state of the
        # underlying process
        def self.update_deployment_states(plan)
            # We first announce all the dead processes and only then call
            # #cleanup_dead_connections, thus avoiding to disconnect connections
            # between already-dead processes

            handle_dead_deployments(plan)
            trigger_ready_deployments(plan)
        end

        def self.handle_dead_deployments(plan)
            all_dead_deployments = Set.new
            server_config = Syskit.conf.each_process_server_config.to_a
            server_config.each do |config|
                begin
                    dead_deployments = config.client.wait_termination(0)
                rescue ::Exception => e
                    deployments = abort_process_server(plan, config)
                    all_dead_deployments.merge(deployments)
                    plan.execution_engine.add_framework_error(e, "update_deployment_states")
                    next
                end

                dead_deployments.each do |p, exit_status|
                    d = Deployment.deployment_by_process(p)
                    unless d.finishing?
                        d.warn "#{p.name} unexpectedly died on process server #{config.name}"
                    end
                    all_dead_deployments << d
                    d.dead!(exit_status)
                end
            end
        end

        def self.trigger_ready_deployments(plan)
            not_ready_deployments = find_all_not_ready_deployments(plan)
            not_ready_deployments.each do |process_server_name, deployments|
                server_config = Syskit.conf.process_server_config_for(process_server_name)
                wait_result = server_config.client.wait_running(
                    *deployments.map { |d| d.arguments[:process_name] }
                )
                wait_result.each do |process_name, result|
                    next unless result

                    deployment = deployments.find { |d| d.process_name == process_name }

                    if result[:error]
                        deployment.ready_event.emit_failed(result[:error])
                    elsif result[:iors]
                        deployment.update_remote_tasks(result[:iors])
                    end
                end
            end
        end

        def self.abort_process_server(plan, process_server)
            client = process_server.client
            # Before we can terminate Syskit, we need to abort all
            # deployments that were managed by this client
            deployments = plan.find_tasks(Syskit::Deployment)
                              .find_all { |t| t.arguments[:on] == process_server.name }
            deployments.each { |t| t.aborted_event.emit if !t.pending? && !t.finished? }
            Syskit.conf.remove_process_server(process_server.name)
        end

        def self.find_all_not_ready_deployments(plan)
            # Must also check if the deployment task is finishing in case it is
            # stopped before becoming ready and if the ready event is pending,
            # which would mean that it the deployment is already updating its
            # remote tasks
            valid_running_deployment_tasks =
                plan.find_tasks(Syskit::Deployment)
                    .running
                    .find_all do |dep_task|
                    !dep_task.ready? && !dep_task.finishing? && !dep_task.ready_event.pending?
                end
            valid_running_deployment_tasks.group_by { |t| t.arguments[:on] }
        end
    end
end
