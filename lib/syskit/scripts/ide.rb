require 'syskit/gui/ide'
require 'roby/standalone'
require 'syskit/scripts/common'
require 'vizkit'

load_all = false
parser = OptionParser.new do |opt|
    opt.banner = <<-EOD
Usage: ide [file] [options]
Loads the models from this bundle and allows to browse them. If a file is given, only this file is loaded.
    EOD

    opt.on '--all', '-a', "Load all models from all active bundles instead of only the ones from the current" do
        load_all = true
    end
end
Syskit::Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using_plugins 'syskit'
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Roby.app.ignore_all_load_errors = true

direct_files, model_names = remaining.partition do |arg|
    File.file?(arg)
end
# Load all task libraries if we don't get a file to require
Roby.app.auto_load_all = load_all
Roby.app.auto_load_models = direct_files.empty?
Roby.app.additional_model_files.concat(direct_files)

Syskit::Scripts.run do
    Orocos.initialize
    Roby.app.syskit_engine.prepare
    main = Syskit::GUI::IDE.new
    main.window_title = "Syskit IDE - #{Roby.app.app_name}"

    main.restore_from_settings
    main.show
    Vizkit.exec
    main.save_to_settings
    main.settings.sync
end


