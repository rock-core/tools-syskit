require 'roby/standalone'
require 'optparse'
require 'orocos'
require 'orocos/roby'
require 'orocos/roby/app'

output_type = 'txt'
output_file = nil
connection_policies = true
debug = false
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate_deployment [options] deployment_name"
    opt.on('-r NAME', '--robot=NAME[,TYPE]', String, 'the robot name used as context to the deployment') do |name|
        name, type = name.split(',')
        Roby.app.robot(name, type||name)
    end
    opt.on('-o TYPE[:file]', '--output=TYPE[:file]', String, 'in what format to output the result (can be: txt, dot or svg), defaults to txt') do |output_arg|
        output_type, output_file = output_arg.split(':')
        output_type = output_type.downcase
        if output_type != 'txt' && !output_file
            STDERR.puts "you must specify an output file for the dot and svg outputs"
            exit(1)
        end
    end
    opt.on('--debug', "turn debugging output on") do
        debug = true
    end
    opt.on('--no-policies', "don't compute the connection policies") do
        connection_policies = false
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

Roby.filter_backtrace do
    Roby.app.setup
    if debug
        Orocos::RobyPlugin::Engine.logger = Logger.new(STDOUT)
        Orocos::RobyPlugin::Engine.logger.formatter = Roby.logger.formatter
        Orocos::RobyPlugin::Engine.logger.level = Logger::DEBUG
    end
    Roby.app.apply_orocos_deployment(remaining.first, connection_policies)
end

case output_type
when "txt"
    pp Roby.app.orocos_engine
when "dot"
    File.open(output_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_engine.to_dot
    end
when "svg"
    Tempfile.open('roby_orocos_deployment') do |io|
        io.write Roby.app.orocos_engine.to_dot
        io.flush

        File.open(output_file, 'w') do |output_io|
            output_io.puts(`dot -Tsvg #{io.path}`)
        end
    end
end

