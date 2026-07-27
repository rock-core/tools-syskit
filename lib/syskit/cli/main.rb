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

                config_path = ["config", "robots", "ROBOT.yml"]
                merged_hash = app.find_files(
                    *config_path, all: true, order: :specific_last
                ).each_with_object({}) do |path, sysdef_hash|
                    values = YAML.safe_load(File.read(path)) || {}

                    # Define a recursive merging rule
                    merger = proc do |key, old_val, new_val|
                        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
                            # If both are hashes, merge them recursively
                            old_val.merge(new_val, &merger)
                        elsif old_val.is_a?(Array) && new_val.is_a?(Array)
                            # If both are arrays, combine them
                            old_val + new_val
                        else
                            # For simple values the newer file wins
                            new_val
                        end
                    end
                    sysdef_hash.merge!(values, &merger)
                end

                if options[:key].empty?
                    result = merged_hash
                elsif options[:key].size == 1
                    key_query = options[:key].first
                    keys = key_query.split(".")

                    current = merged_hash
                    has_key = true
                    keys.each do |k|
                        if current.is_a?(Hash) && current.has_key?(k)
                            current = current[k]
                        else
                            has_key = false
                            break
                        end
                    end

                    if !has_key
                        $stderr.puts "Error: Key '#{key_query}' not found."
                        exit 1
                    end

                    result = current
                else
                    # Process cumulative key filtering
                    merger = proc do |key, old_val, new_val|
                        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
                            old_val.merge(new_val, &merger)
                        elsif old_val.is_a?(Array) && new_val.is_a?(Array)
                            old_val + new_val
                        else
                            new_val
                        end
                    end

                    accumulated_hash = {}
                    options[:key].each do |key_query|
                        keys = key_query.split(".")

                        current = merged_hash
                        has_key = true
                        keys.each do |k|
                            if current.is_a?(Hash) && current.has_key?(k)
                                current = current[k]
                            else
                                has_key = false
                                break
                            end
                        end

                        if !has_key
                            $stderr.puts "Error: Key '#{key_query}' not found."
                            exit 1
                        end

                        # Reconstruct the nested hash for this path
                        nested_path_hash = keys.reverse.reduce(current) { |v, k| { k => v } }
                        accumulated_hash = accumulated_hash.merge(nested_path_hash, &merger)
                    end
                    result = accumulated_hash
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
