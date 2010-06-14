require 'roby'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

robot_type, robot_name = nil
debug = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate [options] deployment\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
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
if remaining.empty?
    STDERR.puts parser
    exit(1)
end
deployment_file     = remaining.shift
additional_services = remaining.dup

Roby.filter_backtrace do
    Roby.app.setup
    Roby.app.using_plugins 'orocos'
    Roby.app.filter_backtraces = !debug
    if debug
        Orocos::RobyPlugin::Engine.logger = Logger.new(STDOUT)
        Orocos::RobyPlugin::Engine.logger.formatter = Roby.logger.formatter
        Orocos::RobyPlugin::Engine.logger.level = Logger::DEBUG
    end

    Roby.app.run do
        Roby.execute do
            Roby.app.load_orocos_deployment(deployment_file)
            additional_services.each do |service_name|
                Roby.app.orocos_engine.add service_name
            end
            Roby.app.orocos_engine.resolve
            if !Roby.engine.scheduler
                require 'roby/schedulers/basic'
                Roby.engine.scheduler = Roby::Schedulers::Basic.new
            end
            tasks = Roby.plan.find_tasks(Orocos::RobyPlugin::Component).
                roots(Roby::TaskStructure::Hierarchy).to_value_set
            tasks.each { |t| Roby.plan.add_mission(t) }
        end
    end
end

