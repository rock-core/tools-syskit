require 'roby/standalone'
require 'syskit/scripts/common'
require 'Qt'
require 'syskit/gui/model_browser'

Scripts = Syskit::Scripts

parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: system_model [options]
Loads the models listed by robot_name, and outputs their model structure
    EOD
end
Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'syskit'
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Syskit.conf.ignore_load_errors = true

app = Qt::Application.new(ARGV)


Scripts.run do
    if remaining.empty?
        # Load all task libraries
        Roby.app.syskit_load_all
    else
        files, projects = remaining.partition { |path| File.file?(path) }
        projects.each do |project_name|
            Roby.app.use_deployments_from(project_name)
        end
        files.each do |file|
            require file
        end
    end

    Roby.app.syskit_engine.prepare

    main = Syskit::GUI::ModelBrowser.new
    main.resize(800, 500)
    main.show

    $qApp.exec
end
