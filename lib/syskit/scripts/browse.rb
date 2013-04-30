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

direct_files, model_names = remaining.partition do |arg|
    File.file?(arg)
end
if !direct_files.empty?
    include Scripts::SingleFileDSL
    self.profile_name = "SyskitBrowse"
end

# Load all task libraries if we don't get a file to require
Roby.app.syskit_load_all = direct_files.empty?

app = Qt::Application.new(ARGV)
Scripts.run do
    direct_files.each do |path|
        require path
    end
    Roby.app.syskit_engine.prepare

    main = Syskit::GUI::ModelBrowser.new

    # Select the model given on the command line (if any)
    if !model_names.empty?
        model = begin
                    constant(model_names.first)
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
