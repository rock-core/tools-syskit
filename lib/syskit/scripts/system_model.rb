require 'roby/standalone'
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

# We don't need the process server, win some startup time
Roby.app.using_plugins 'orocos'
Roby.app.orocos_only_load_models = true
Roby.app.orocos_disables_local_process_server = true

Scripts.setup_output("system_model", Roby.app.orocos_system_model) do
    Roby.app.orocos_system_model.to_dot
end

Scripts.run do
    files, projects = remaining.partition { |path| File.file?(path) }
    projects.each do |project_name|
        Roby.app.use_deployments_from(project_name)
    end
    files.each do |file|
        Roby.app.orocos_engine.load_composite_file file
    end
    # Do compute the automatic connections
    Roby.app.orocos_system_model.each_composition do |c|
        c.compute_autoconnection
    end
end

Scripts.generate_output
