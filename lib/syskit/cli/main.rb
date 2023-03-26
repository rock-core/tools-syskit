# frozen_string_literal: true

require "roby/cli/main"
require "syskit/cli/gen_main"
require "syskit/cli/doc_main"

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
        end
    end
end
