# frozen_string_literal: true

require "roby/cli/exceptions"
require "syskit/cli/doc/each_model_file"
require "syskit/cli/doc/networks"

module Syskit
    module CLI
        # Entry point for `syskit doc` subcommands
        class DocMain < Thor
            namespace :doc

            desc "networks TARGET_PATH",
                 "generate SVGs for anything that is a Syskit network"
            option :robot,
                   aliases: "r", type: :string, default: "default",
                   desc: "robot configuration to document"
            option :only_robot, type: :boolean, default: true
            option :common_path,
                   type: :string, default: nil,
                   desc: "path to common models for symlinking"
            def networks(target_path)
                MetaRuby.keep_definition_location = true
                roby_app_configure

                target_path = Pathname.new(target_path).expand_path
                FileUtils.mkdir_p target_path

                paths = each_model_file_for_robot.to_a
                require_model_files(paths)
                Doc.generate_network_graphs(roby_app, paths, target_path)

            ensure
                Roby.app.cleanup
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                def roby_app
                    Roby.app
                end

                def roby_app_configure
                    roby_app.require_app_dir
                    roby_app.using "syskit"
                    roby_app.development_mode = false
                    Syskit.conf.only_load_models = true

                    roby_app_configure_robot
                    roby_app.setup
                end

                def roby_app_configure_robot
                    robot_name, robot_type = options[:robot].split(",")

                    roby_app.setup_robot_names_from_config_dir
                    roby_app.robot(robot_name, robot_type)
                end

                def models_path
                    roby_app.app_path / "models"
                end

                def robot_names
                    robot_names = [roby_app.robot_name, roby_app.robot_type]
                    robot_names << "default" unless options[:only_robot]
                    robot_names
                end

                def each_model_file_for_robot
                    return enum_for(:each_model_file_for_robot) unless block_given?

                    Doc.each_model_file_for_robot(
                        models_path, robot_names, robots: roby_app.robots
                    ) { |path| yield(path) }
                end

                def require_model_files(paths)
                    orogen_path = models_path / "orogen"
                    paths.each do |p|
                        next if p.dirname == orogen_path

                        require p.to_s
                    end
                end
            end
        end
    end
end
