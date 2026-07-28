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

            desc "config ROBOT", "print the configuration of a given robot"
            option :key, type: :string, repeatable: true, default: []
            option :from_bundle, type: :string, default: nil
            def config(robot_name)
                require "yaml"

                if (from_bundle = options[:from_bundle])
                    require "rock/bundle" unless defined?(Rock::Bundles)

                    bundle = Rock::Bundles.each_bundle.find { |b| b.name == from_bundle }
                    if bundle
                        Dir.chdir(bundle.path)
                    else
                        $stderr.puts "No bundle named '#{from_bundle}' found."
                        $stderr.puts "Available bundles are: #{Rock::Bundles.each_bundle.map(&:name).sort.join(', ')}"
                        exit 1
                    end
                end

                app = Roby.app
                app.require_app_dir
                app.load_config_yaml
                app.setup_robot_names_from_config_dir
                app.robot(robot_name)

                merger = proc do |_, old_val, new_val|
                    if old_val.is_a?(Hash) && new_val.is_a?(Hash)
                        old_val.merge(new_val, &merger)
                    elsif old_val.is_a?(Array) && new_val.is_a?(Array)
                        old_val + new_val
                    else
                        new_val
                    end
                end

                config_path = ["config", "robots", "ROBOT.yml"]
                merged_hash = app.find_files(
                    *config_path, all: true, order: :specific_last
                ).each_with_object({}) do |path, config_hash|
                    values = YAML.safe_load(File.read(path)) || {}
                    config_hash.merge!(values, &merger)
                end

                if options[:key].empty?
                    result = merged_hash
                else
                    resolved_queries = options[:key].map do |key_query|
                        keys = key_query.split(".")
                        parent = keys.size > 1 ? merged_hash.dig(*keys[0...-1]) : merged_hash

                        unless parent.is_a?(Hash) && parent.has_key?(keys.last)
                            $stderr.puts "Error: Key '#{key_query}' not found."
                            exit 1
                        end

                        [keys, merged_hash.dig(*keys)]
                    end

                    if resolved_queries.size == 1
                        result = resolved_queries.first.last
                    else
                        result = resolved_queries.reduce({}) do |accum, (keys, value)|
                            nested_path_hash = keys.reverse.reduce(value) { |v, k| { k => v } }
                            accum.merge(nested_path_hash, &merger)
                        end
                    end
                end

                puts YAML.dump(result)
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
