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
            for config in Syskit.conf.each_process_server_config
                server = config.client
                dead_deployments = server.wait_termination(0)
                dead_deployments.each do |p, exit_status|
                    d = Deployment.all_deployments[p]
                    if !d.finishing?
                        Syskit.warn "#{p.name} unexpectedly died on #{config.name}"
                    end
                    all_dead_deployments << d
                    d.dead!(exit_status)
                end
            end

            for deployment in all_dead_deployments
                deployment.cleanup_dead_connections
            end
        end
    end
end

