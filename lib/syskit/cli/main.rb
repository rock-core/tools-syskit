# frozen_string_literal: true

require "roby/cli/main"
require "syskit/cli/gen_main"
require "syskit/cli/doc_main"
require "syskit/telemetry/cli"

module Syskit
    module CLI
        class Main < Roby::CLI::Main
            subcommand "gen", GenMain

            desc "doc [TARGET_DIR]", "generate documentation"
            subcommand "doc", DocMain

            desc "orogen-test",
                 "run Syskit script(s) aimed at unit-testing an oroGen project",
                 hide: true
            option :workdir, type: :string, default: nil
            option :logs, type: :string, default: nil
            option :logs_base, type: :string, default: nil
            option :log, type: :string, repeatable: true, default: []
            def orogen_test(*args)
                syskit_path = File.expand_path("../../../bin/syskit", __dir__)
                minitest_args, files = args.partition { |p| p.start_with?("-") }
                files = files.map { |p| File.realpath(p) }

                workdir = options[:workdir] || Dir.pwd

                extra_args = ["--keep-logs"]
                extra_args << "--logs" << options[:logs] if options[:logs]
                extra_args << "--logs-base" << options[:logs_base] if options[:logs_base]
                extra_args.concat(options[:log].map { |l| "--log=#{l}" })

                system(syskit_path, "gen", "app", workdir) unless File.directory?(workdir)
                Process.exec(syskit_path, "test", "--live", *extra_args, *files, "--",
                             *minitest_args, chdir: workdir)
            end

            desc "telemetry",
                 "commands related to monitoring and commanding a running Syskit system"
            subcommand "telemetry", Telemetry::CLI

            desc "bundle_dir NAME", "print the directory of a bundle"
            def bundle_dir(name)
                require "rock/bundle" unless defined?(Rock::Bundles)

                bundle = Rock::Bundles.each_bundle.find { |b| b.name == name }
                if bundle
                    puts bundle.path
                else
                    $stderr.puts "No bundle named '#{name}' found."
                    $stderr.puts "Available bundles are: #{Rock::Bundles.each_bundle.map(&:name).sort.join(', ')}"
                    exit 1
                end
            end

            no_commands do
                def setup_interface(*, **)
                    interface_version = options[:interface_version] || 1
                    require "syskit/interface/v2" if interface_version == 2
                    super
                end
            end
        end
    end
end
