require 'roby'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

deploy_all = false
deploy_only = nil
dont_act = false
save_dir, save_name = nil
parser = OptionParser.new do |opt|
    opt.banner = "scripts/orocos/configure [options] deployment
  where 'deployment' is either the name of a deployment in config/deployments,
  or a file that should be loaded to get the desired deployment
  
scripts/orocos/configure -r ROBOT --all [options]
scripts/orocos/configure -r ROBOT --deployments NAME1,NAME2 [options]
  deploys all tasks and devices that are defined in the configuration
  file of ROBOT
"

  opt.on("--dont-act", "do not call #configure on the orocos tasks, only call the configure method in Roby") do
        dont_act = true
  end

  opt.on('-a', "--all", "deploys all tasks that are defined in the robot's configuration (requires -r)") do
      deploy_all = true
  end
  opt.on('-d NAMES', '--deployments=NAMES', String, 'deploy all tasks that are part of the comma-separated list of deployments (required -r)') do |names|
      deploy_only = names.split(',')
  end
  opt.on('-s DIR', '--save=DIR', String, 'once configuration finished, save the resulting configuration in DIR') do |dir|
      save_dir = dir
  end
  opt.on('--save-name=NAME', String, 'save the configuration as NAME. By default, the orocos task names are used') do |name|
      save_name = name
  end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty? && !deploy_all && !deploy_only
    STDERR.puts parser
    exit(1)
end
deployment_file     = remaining.shift
additional_services = remaining.dup

Orocos::ConfigurationManager.make_own_logger(Logger::INFO)

error = Scripts.run do
    Roby.app.run do
        Roby.execute do
            Roby.engine.scheduler = nil
            if deploy_all || deploy_only
                deployments = Roby.app.orocos_engine.deployments.
                    values.map(&:to_a).flatten.sort.uniq
                if deploy_only
                    deployments.delete_if { |name| !deploy_only.include?(name) }
                end
                deployments = deployments.map do |name|
                    Roby.app.orocos_deployments[name]
                end

                deployments.each do |deployment_model|
                    Roby.plan.add(deployment_task = deployment_model.new)
                    deployment_task.robot = Roby.app.orocos_engine.robot
                    deployment_task.instanciate_all_tasks.each do |t|
                        Roby.plan.add_permanent(t)
                    end
                end
                Roby.app.orocos_engine.prepare
                Roby.app.orocos_engine.compute_system_network
                Roby.engine.garbage_collect

            else
                if deployment_file != '-'
                    Roby.app.load_orocos_deployment(deployment_file)
                end
                additional_services.each do |service_name|
                    service_name = Scripts.resolve_service_name(service_name)
                    Roby.app.orocos_engine.add_mission service_name
                end
                Roby.app.orocos_engine.resolve
            end


            ready_ev = Roby.plan.find_tasks(Orocos::RobyPlugin::Deployment).
                inject(Roby::AndGenerator.new) do |ev, task|
                    task.start!
                    ev << task.ready_event
                end

            Roby.plan.find_tasks(Orocos::RobyPlugin::TaskContext).
                each do |t|
                    # Mark it as non-executable to avoid that it gets scheduled
                    t.allow_automatic_setup = false
                end

            # Wait for the deployments to be started
            ready_ev.if_unreachable(true) do
                Robot.info "failed to start the deployments"
                Roby.log_pp(ready_ev.unreachability_reason, Robot, :info)
                Roby.engine.quit
            end
            ready_ev.on do |event|
                Robot.info "all deployments are up and running"
                tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::TaskContext).to_a

                failed = tasks.find_all do |t|
                    begin
                        method_name =
                            if dont_act then 'configure'
                            else 'setup'
                            end

                        if t.execution_agent
                            Robot.info "calling #{t.class.name}##{method_name} on #{t}, deployed in #{t.execution_agent.model.deployment_name}"
                        else
                            Robot.info "calling #{t.class.name}##{method_name} on #{t}"
                        end
                        t.send(method_name)
			false
                    rescue Exception => e
                        Robot.warn "#{t.class.name}##{method_name} fails with"
                        Roby.display_exception(STDERR, e)
                        true
                    end
                end

                if failed.empty?
                    Robot.info "the #configure method worked on all tasks"
                else
                    Robot.error "the tasks #{failed.map(&:orocos_name).join(", ")} failed to configure (see above for backtrace)"
                end

                if save_dir
                    FileUtils.mkdir_p(save_dir)
                    Robot.orocos.dump_all_config(save_dir, save_name)
                end
                Roby.engine.quit
            end
        end
    end
end

if error
    exit(1)
end


