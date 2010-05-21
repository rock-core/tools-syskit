require 'roby'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

robot_type, robot_name = nil
debug = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/configure [options] deployment\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name used as context to the deployment') do |name|
        robot_name, robot_type = name.split(',')
        Roby.app.robot(name, robot_type||robot_name)
    end
    opt.on('--debug', "turn debugging output on") do
        debug = true
    end
    opt.on_tail('-h', '--help', 'this help message') do
	STDERR.puts opt
	exit
    end
end
remaining = parser.parse(ARGV)
if remaining.size != 1
    STDERR.puts parser
    exit(1)
end
deployment_file = remaining.first

Roby.filter_backtrace do
    Roby.app.setup
    Roby.app.using_plugins 'orocos'
    Roby.app.filter_backtraces = !debug
    if debug
        Orocos::RobyPlugin::Engine.logger = Logger.new(STDOUT)
        Orocos::RobyPlugin::Engine.logger.formatter = Roby.logger.formatter
        Orocos::RobyPlugin::Engine.logger.level = Logger::DEBUG
    end

    Roby.app.orocos_auto_configure = false

    # No need to run any scheduler. We will simply start all deployments, and
    # when they are all started call the #configure methods
    Roby.app.run do
        Roby.execute do
            Roby.engine.scheduler = nil
            Roby.app.apply_orocos_deployment(deployment_file)
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
                Roby.engine.quit
            end
            ready_ev.on do |event|
                Robot.info "all deployments are up and running"

                failed = tasks.find_all do |t|
                    begin
                        if t.respond_to?(:configure)
                            Robot.info "calling #{t.class.name}#configure on #{t}, deployed in #{t.execution_agent.model.deployment_name}"
                            t.configure
                        end
                        false
                    rescue Exception => e
                        Robot.warn "#{t.class.name}#configure fails with"
                        Roby.log_pp(e, Robot, :warn)
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

