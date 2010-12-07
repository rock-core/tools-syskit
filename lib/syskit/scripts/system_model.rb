require 'orocos/roby/scripts/common'
Scripts = Orocos::RobyPlugin::Scripts

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: scripts/orocos/system_model [options]
Loads the models listed by robot_name, and outputs their model structure
    EOD
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

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

Scripts.run do
    files, projects = remaining.partition { |path| File.file?(path) }
    projects.each do |project_name|
        Roby.app.use_deployments_from(project_name)
    end
    files.each do |file|
        Roby.app.load_system_model file
    end
    # Do compute the automatic connections
    Roby.app.orocos_system_model.each_composition do |c|
        c.compute_autoconnection
    end
end

# Now output them
case output_type
when "txt"
    pp Roby.app.orocos_system_model
when "dot"
    File.open(output_file, 'w') do |output_io|
        output_io.puts Roby.app.orocos_system_model.to_dot
    end
when "png"
    io = IO.popen("dot -Tpng -o#{output_file}", "w")
    io.write(Roby.app.orocos_system_model.to_dot)
    io.flush
    io.close

when "svg"
    
    Tempfile.open('roby_orocos_system_model') do |io|
        io.write Roby.app.orocos_system_model.to_dot
        io.flush

        File.open(output_file, 'w') do |output_io|
            output_io.puts(`dot -Tsvg #{io.path}`)
        end
    end
end
if output_file
    STDERR.puts "exported result to #{output_file}"
end

