# frozen_string_literal: true

require "roby"
require "syskit/gui/runtime_main"
require "syskit/scripts/common"

parser = OptionParser.new do |opt|
    opt.banner = <<~BANNER_TEXT
        Usage: runtime
        Connect to a running Syskit and allow interacting with it
    BANNER_TEXT
end

options = {}
Roby::Application.host_options(parser, options)
Syskit::Scripts.common_options(parser, true)
parser.parse(ARGV)

error = Roby.display_exception do
    $qApp.disable_threading

    main = Syskit::GUI::RuntimeMain.new(
        host: options[:host], port: options[:port]
    )
    main.window_title = "Syskit #{Roby.app.app_name} #{Roby.app.robot_name} @#{options[:host]}"

    main.restore_from_settings
    main.show

    Vizkit.exec

    main.save_to_settings
    main.settings.sync
end

