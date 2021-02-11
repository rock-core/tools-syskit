# frozen_string_literal: true

require "roby/standalone"
require "syskit/scripts/common"
require "Qt"
require "syskit/gui/browse"

Scripts = Syskit::Scripts

load_all = false
parser = OptionParser.new do |opt|
    opt.banner = <<~BANNER_TEXT
        Usage: browse [file] [options]
        Loads the models from this bundle and allows to browse them. If a file is given, only this file is loaded.
    BANNER_TEXT

    opt.on "--all", "-a", "Load all models from all active bundles instead of only the ones from the current" do
        load_all = true
    end
end
Scripts.common_options(parser, true)
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
Roby.app.auto_load_models = direct_files.empty?
Roby.app.additional_model_files.concat(direct_files)

app = Qt::Application.new(ARGV)
settings = Qt::Settings.new("syskit", "")

Scripts.run do
    main = Syskit::GUI::Browse.new

    # Select the model given on the command line (if any)
    unless model_names.empty?
        model = begin
                    constant(model_names.first)
                rescue NameError
                    Syskit.warn "cannot find a model named #{remaining.first}"
                end
        if model
            main.select_by_model(model)
        end
    end

    size = settings.value("MainWindow/size", Qt::Variant.new(Qt::Size.new(800, 600))).to_size
    main.resize(size)
    main.show
    $qApp.exec
    settings.setValue("MainWindow/size", Qt::Variant.new(main.size))
    settings.sync
end
