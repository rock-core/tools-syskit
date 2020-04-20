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

        def self.abort_process_server(plan, process_server)
            client = process_server.client
            # Before we can terminate Syskit, we need to abort all
            # deployments that were managed by this client
            deployments = plan.find_tasks(Syskit::Deployment)
                              .find_all { |t| t.arguments[:on] == process_server.name }
            deployments.each { |t| t.aborted_event.emit if !t.pending? && !t.finished? }
            Syskit.conf.remove_process_server(process_server.name)
        end
    end
end
