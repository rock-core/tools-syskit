require 'roby'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/configure [options] deployment\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end
deployment_file     = remaining.shift
additional_services = remaining.dup

error = Scripts.run do
    Roby.app.run do
        Roby.execute do
            Roby.engine.scheduler = nil
            if deployment_file != '-'
                Roby.app.load_orocos_deployment(deployment_file)
            end
            additional_services.each do |service_name|
                service_name = Scripts.resolve_service_name(service_name)
                Roby.app.orocos_engine.add_mission service_name
            end
            Roby.app.orocos_engine.resolve

            ready_ev = Roby.plan.find_tasks(Orocos::RobyPlugin::Deployment).
                inject(Roby::AndGenerator.new) do |ev, task|
                    task.start!
                    ev << task.ready_event
                end

            tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::Component).
                to_value_set
            Roby.each_cycle do |plan|
                if tasks.all?(&:executable?)
                    Robot.info "succeeded"
                    Roby.engine.quit
                else
                    failed = tasks.find_all(&:failed_to_start?)
                    if !failed.empty?
                        failed.each do |t|
                            Roby.log_pp(t.failure_reason, Robot, :info)
                        end
                        Roby.engine.quit
                    end
                end
            end

            # Wait for the deployments to be started
            ready_ev.if_unreachable(true) do
                Robot.info "failed to start the deployments"
                Roby.log_pp(ready_ev.unreachability_reason, Robot, :info)
                Roby.engine.quit
            end
            ready_ev.on do |event|
                Robot.info "all deployments are up and running"


                failed = tasks.find_all do |t|
                    begin
                        if !t.setup?
			    if t.execution_agent
			    	Robot.info "calling #{t.class.name}#setup on #{t}, deployed in #{t.execution_agent.model.deployment_name}"
			    else
			    	Robot.info "calling #{t.class.name}#setup on #{t}"
			    end
                            t.setup
                        end
			false
                    rescue Exception => e
                        Robot.warn "#{t.class.name}#configure fails with"
                        Roby.display_exception(STDERR, e)
                        true
                    end
                end

                if failed.empty?
                    Robot.info "the #configure method worked on all tasks"
                end
                Roby.engine.quit
            end
        end
    end
end

if error
    exit(1)
end


