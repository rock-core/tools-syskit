require 'roby/standalone'
require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

compute_policies    = true
compute_deployments = true
remove_compositions = false
validate_network    = true
parser = OptionParser.new do |opt|
    opt.banner = "Usage: scripts/orocos/instanciate [options] deployment [additional services]
   'deployment' is either the name of a deployment in config/deployments,
    or a file that should be loaded to get the desired deployment
    'additional services', if given, refers to services defined with
    'define' that should be added
    "
    opt.on('--no-policies', "don't compute the connection policies") do
        compute_policies = false
    end
    opt.on('--no-deployments', "don't deploy") do
        compute_deployments = false
    end
    opt.on("--no-compositions", "remove all compositions from the generated data flow graph") do
        remove_compositions = true
    end
    opt.on("--dont-validate", "do not validate the generate system network") do
        validate_network = false
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end
deployment_file     = remaining.shift
additional_services = remaining.dup

# Generate a default name if the output file name has not been given
output_type, output_file = Scripts.output_type, Scripts.output_file
if output_type != 'txt' && !output_file
    output_file =
        if base_name = (Scripts.robot_name || Scripts.robot_type)
            "#{base_name}.#{output_type}"
        else
            "system_model.#{output_type}"
        end
end

# We don't need the process server, win some startup time
Roby.app.using_plugins 'orocos'
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true

error = Scripts.run do
    GC.start

    Scripts.tic
    Roby.app.load_orocos_deployment(deployment_file)
    additional_services.each do |service_name|
        Roby.app.orocos_engine.add service_name
    end
    Scripts.toc_tic "loaded deployment in %.3f seconds"

    Roby.app.orocos_engine.
        resolve(:export_plan_on_error => false,
            :compute_policies => compute_policies,
            :compute_deployments => compute_deployments,
            :validate_network => validate_network)
    Scripts.toc_tic "computed deployment in %.3f seconds"
end

if error
    exit(1)
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
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
        end
    end
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_hierarchy
        io.flush

        File.open(hierarchy_file, 'w') do |output_io|
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
        end
    end
end

if output_file
    STDERR.puts "output task hierarchy in #{hierarchy_file}"
    STDERR.puts "output dataflow in #{dataflow_file}"
end

