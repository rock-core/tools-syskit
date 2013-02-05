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
Roby.app.ignore_all_load_errors = true
Roby.app.syskit_load_all = true

app = Qt::Application.new(ARGV)


Scripts.run do
    # Load all task libraries
    Roby.app.syskit_engine.prepare

    main = Syskit::GUI::ModelBrowser.new
    # Select the model given on the command line (if any)
    if !remaining.empty?
        model = begin
                    constant(remaining.first)
                rescue NameError
                    Syskit.warn "cannot find a model named #{remaining.first}"
                end
        if model
            main.select_by_module(model)
        end
    end

    main.resize(800, 500)
    main.show

    $qApp.exec
end
