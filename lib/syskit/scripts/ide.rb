# frozen_string_literal: true

require "roby"
require "syskit/gui/ide"
require "syskit/scripts/common"
require "vizkit"

Roby.app.require_app_dir

load_all = false
runtime_mode = nil
runtime_only = false
test_mode = false
parser = OptionParser.new do |opt|
    opt.banner = <<~BANNER_TEXT
        Usage: ide [file] [options]
        Loads the models from this bundle and allows to browse them. If a file is given, only this file is loaded.
    BANNER_TEXT

    opt.on "--all", "-a", "Load all models from all active bundles instead of only the ones from the current" do
        load_all = true
    end

    opt.on "-t", "--test", "Start with tests already running" do
        test_mode = true
    end

    opt.on "--no-runtime", "Do not attempt to connect to a running syskit instance" do
        runtime_mode = false
    end

    opt.on "--runtime", "Start in runtime mode" do
        runtime_mode = true
    end

    opt.on "--runtime-only", "only show runtime control functionalities" do
        runtime_mode = true
        runtime_only = true
    end
end
options = {}
Roby::Application.host_options(parser, options)
Roby.app.guess_app_dir unless runtime_only
Syskit::Scripts.common_options(parser, true)
remaining = parser.parse(ARGV)

# We don't need the process server, win some startup time
Roby.app.using "syskit"
Syskit.conf.only_load_models = true
Syskit.conf.disables_local_process_server = true
Roby.app.ignore_all_load_errors = true

direct_files, model_names = remaining.partition do |arg|
    File.file?(arg)
end
# Load all task libraries if we don't get a file to require
Roby.app.auto_load_all = load_all
Roby.app.auto_load_models = false
Roby.app.additional_model_files.concat(direct_files)

$qApp.disable_threading

Syskit::Scripts.run do
    Orocos.initialize
    main = Syskit::GUI::IDE.new(
        robot_name: Roby.app.robot_name,
        runtime_only: runtime_only,
        runtime: runtime_mode, tests: test_mode,
        host: options[:host], port: options[:port]
    )
    main.window_title = "Syskit #{Roby.app.app_name} #{Roby.app.robot_name} @#{options[:host]}"

    main.restore_from_settings
    main.show
    Vizkit.exec
    main.save_to_settings
    main.settings.sync
end
