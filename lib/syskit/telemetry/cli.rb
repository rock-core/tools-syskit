# frozen_string_literal: true

require "roby"
require "roby/interface/base"

module Syskit
    module Telemetry
        # Implementation of `syskit telemetry`
        class CLI < Thor
            desc "ui",
                 "open a UI to interface with a running Syskit system"
            option :host,
                   type: :string, doc: "host[:port] to connect to",
                   default: "localhost:#{Roby::Interface::DEFAULT_PORT_V2}"
            option :robot,
                   aliases: "r",
                   type: :string, doc: "robot config option to pass to `syskit run`",
                   default: "default"
            option :set,
                   type: :string, doc: "--set options to pass to `syskit run`",
                   repeatable: true, default: []
            def ui
                roby_setup
                host, port = parse_host_port(
                    options[:host], default_port: Roby::Interface::DEFAULT_PORT_V2
                )

                require "syskit/telemetry/ui/runtime_state"
                $qApp.disable_threading # rubocop:disable Style/GlobalVars

                require "syskit/scripts/common"
                Syskit::Scripts.run do
                    runtime_state(host, port)
                end
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                def roby_setup
                    Roby.app.using "syskit"
                    Syskit.conf.only_load_models = true
                    # We don't need the process server, win some startup time
                    Syskit.conf.disables_local_process_server = true
                    Roby.app.ignore_all_load_errors = true
                    Roby.app.development_mode = false

                    Roby.app.auto_load_all = false
                    Roby.app.auto_load_models = false
                end

                def parse_host_port(host_port, default_port:)
                    host_port += ":#{default_port}" unless /:\d+$/.match?(host_port)
                    match = /(.*):(\d+)$/.match(host_port)
                    [match[1], Integer(match[2])]
                end

                def create_async_interface(host, port)
                    Orocos.initialize
                    Roby::Interface::V2::Async::Interface.new(host, port: port)
                end

                def create_runtime_state_ui(host, port)
                    interface = create_async_interface(host, port)
                    main = UI::RuntimeState.new(syskit: interface)
                    main.syskit_run_arguments(robot: options[:robot], set: options[:set])
                    main.window_title = "Syskit @#{host}"
                    main
                end

                def runtime_state(host, port)
                    main = create_runtime_state_ui(host, port)

                    main.restore_from_settings
                    main.show
                    Vizkit.exec
                    main.save_to_settings
                    main.settings.sync
                end
            end
        end
    end
end
