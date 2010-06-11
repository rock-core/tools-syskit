require 'roby'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

output_type = 'txt'
output_file = nil
robot_type, robot_name = nil
connection_policies = true
debug = false
remove_compositions = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate [options] deployment\nwhere 'deployment' is either the name of a deployment in config/deployments,\nor a file that should be loaded to get the desired deployment"
    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name used as context to the deployment') do |name|
        robot_name, robot_type = name.split(',')
        Roby.app.robot(name, robot_type||robot_name)
    end
    opt.on('-o TYPE[:file]', '--output=TYPE[:file]', String, 'in what format to output the result (can be: txt, dot, png or svg), defaults to txt') do |output_arg|
        output_type, output_file = output_arg.split(':')
        output_type = output_type.downcase
    end
    opt.on('--debug', "turn debugging output on") do
        debug = true
    end
    opt.on('--no-policies', "don't compute the connection policies") do
        connection_policies = false
    end
    opt.on("--no-compositions", "remove all compositions from the generated data flow graph") do
        remove_compositions = true
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

    Dir.chdir(APP_DIR)
    Roby.app.setup_global_singletons
    Roby.app.setup_drb_server
    Roby.app.apply_orocos_deployment(deployment_file, connection_policies)
end

# Generate a default name if the output file name has not been given
if output_type != 'txt' && !output_file
    output_file =
        if robot_name || robot_type
            "#{robot_name || robot_type}"
        else
            File.basename(deployment_file, File.extname(deployment_file))
        end
end
hierarchy_file = "#{output_file}-hierarchy.#{output_type}"
dataflow_file = "#{output_file}-dataflow.#{output_type}"

case output_type
when "txt"
    pp Roby.app.orocos_engine
when "dot"
    File.open(hierarchy_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_engine.to_dot_hierarchy
    end
    File.open(dataflow_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_engine.to_dot_dataflow(remove_compositions)
    end
when "svg", "png"
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_dataflow(remove_compositions)
        io.flush

        File.open(dataflow_file, 'w') do |output_io|
            output_io.puts(`dot -T#{output_type} #{io.path}`)
        end
    end
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_hierarchy
        io.flush

        File.open(hierarchy_file, 'w') do |output_io|
            output_io.puts(`dot -T#{output_type} #{io.path}`)
        end
    end
end

if output_file
    STDERR.puts "output task hierarchy in #{hierarchy_file}"
    STDERR.puts "output dataflow in #{dataflow_file}"
end

