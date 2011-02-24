require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

compute_policies    = true
compute_deployments = true
remove_compositions = false
remove_loggers      = false
validate_network    = true
test = false
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
    opt.on("--no-loggers", "remove all loggers from the generated data flow graph") do
        remove_loggers = true
    end
    opt.on("--no-compositions", "remove all compositions from the generated data flow graph") do
        remove_compositions = true
    end
    opt.on("--dont-validate", "do not validate the generate system network") do
        validate_network = false
    end
    opt.on('--test', 'test mode: instanciates everything defined in the given file') do
        test = true
    end
end

Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)
if remaining.empty?
    STDERR.puts parser
    exit(1)
end

if test
    test_file = remaining.shift
    test_setup = YAML.load(File.read(test_file))

    outdir = File.join(File.dirname(test_file), 'results', 'instanciate')
    FileUtils.mkdir_p(outdir)

    config = test_setup.delete('configuration') || %w{--no-loggers --no-compositions -osvg}

    default_deployment = test_setup.delete('default_deployment') || '-'
    default_robot = test_setup.delete('default_robot')
    default_def = { 'deployment' => default_deployment, 'robot' => default_robot, 'services' => [] }

    output_option, config = config.partition { |s| s =~ /^-o(\w+)$/ }
    output_option = output_option.first
    if !output_option
        output_option = "-osvg"
    end

    simple_tests = test_setup.delete('simple_tests') || []
    simple_tests.each do |name|
        test_setup[name] = [name]
    end

    test_setup.each do |test_name, test_def|
        if test_def.respond_to?(:to_ary)
            test_def = { 'services' => test_def }
        elsif test_def.respond_to?(:to_str)
            test_def = { 'services' => [test_def] }
        end

        test_def = default_def.merge(test_def)

        cmdline = []
        cmdline.concat(config)
        cmdline << output_option + ":#{test_name}"
        if test_def['robot']
            cmdline << "-r#{test_def['robot']}"
        end
        cmdline << test_def['deployment']
        cmdline.concat(test_def['services'])

        txtlog = File.join(outdir, "#{test_name}-out.txt")
        shellcmd = "#{$0} '#{cmdline.join("' '")}' >> #{txtlog} 2>&1"
        File.open(txtlog, 'w') do |io|
            io.puts test_name
            io.puts shellcmd
            io.puts
        end

        STDERR.print "running test #{test_name}... "
        `#{shellcmd}`
        if $?.exitstatus != 0
            if $?.exitstatus == 2
                STDERR.puts "deployment successful, but dot failed to generate the resulting network"
            else
                STDERR.puts "failed"
            end
        else
            STDERR.puts "success"
        end
    end
    exit(0)

else
    deployment_file     = remaining.shift
    additional_services = remaining.dup
end

require 'roby/standalone'

# Generate a default name if the output file name has not been given
output_type, output_file = Scripts.output_type, Scripts.output_file
if output_type != 'txt' && !output_file
    output_file =
        if base_name = (Scripts.robot_name || Scripts.robot_type)
            base_name
        elsif deployment_file != '-'
            deployment_file
        else
            "instanciate"
        end
end

# We don't need the process server, win some startup time
Roby.app.using_plugins 'orocos'
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true

Scripts.tic
error = Scripts.run do
    GC.start

    if deployment_file != '-'
        Roby.app.load_orocos_deployment(deployment_file)
    end
    additional_services.each do |service_name|
        service_name = Scripts.resolve_service_name(service_name)
        Roby.app.orocos_engine.add service_name
    end
    Scripts.toc_tic "initialized in %.3f seconds"

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

excluded_tasks      = ValueSet.new
if remove_loggers
    excluded_tasks << Orocos::RobyPlugin::Logger::Logger
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
        output_io.puts Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks)
    end
when "x11"
    output_file  = nil
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks)
        io.flush
        `dot -Tx11 #{io.path}`
        if $?.exitstatus != 0
            STDERR.puts "dot failed to display the network"
        end
    end

when "svg", "png"
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_dataflow(remove_compositions, excluded_tasks)
        io.flush

        File.open(dataflow_file, 'w') do |output_io|
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
            if $?.exitstatus != 0
                STDERR.puts "dot failed to generate the network"
                exit(2)
            end
        end
    end
    Tempfile.open('roby_orocos_instanciate') do |io|
        io.write Roby.app.orocos_engine.to_dot_hierarchy
        io.flush

        File.open(hierarchy_file, 'w') do |output_io|
            output_io.puts(`dot -T#{Scripts.output_type} #{io.path}`)
            if $?.exitstatus != 0
                STDERR.puts "dot failed to generate the network"
                exit(2)
            end
        end
    end
end

if output_file
    STDERR.puts "output task hierarchy in #{hierarchy_file}"
    STDERR.puts "output dataflow in #{dataflow_file}"
end

