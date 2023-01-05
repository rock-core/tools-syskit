# frozen_string_literal: true

require "roby/cli/exceptions"
require "syskit/cli/doc/each_model_file"
require "syskit/cli/doc/gen"

module Syskit
    module CLI
        # Entry point for `syskit doc` subcommands
        class DocMain < Thor
            namespace :doc

            desc "gen TARGET_PATH",
                 "generate data to be used by the YARD plugin to augment documentation"
            option :robot,
                   aliases: "r", type: :string, default: "default",
                   desc: "robot configuration to document"
            option :only_robot, type: :boolean, default: true
            option :exclude,
                   type: :array, default: [],
                   desc: "list of path patterns to exclude from documentation"
            option :set,
                   type: :array, default: [],
                   desc: "set some configuration parameters"
            def gen(target_path)
                MetaRuby.keep_definition_location = true
                roby_app_configure
                roby_autoload_orogen_projects

                target_path = Pathname.new(target_path).expand_path
                FileUtils.mkdir_p target_path

                paths = each_model_file_for_robot.to_a
                require_model_files(paths)
                Doc.generate(roby_app, paths, target_path)
            ensure
                Roby.app.cleanup
            end

            no_commands do # rubocop:disable Metrics/BlockLength
                def roby_app
                    Roby.app
                end

                def roby_app_configure
                    apply_set_options(roby_app)

                    roby_app.require_app_dir
                    roby_app.using "syskit"
                    roby_app.development_mode = false
                    Syskit.conf.only_load_models = true

                    roby_app_configure_robot
                    roby_app.setup_for_minimal_tooling
                end

                def apply_set_options(app)
                    (options[:set] || []).each do |kv|
                        app.argv_set << kv
                        Roby::Application.apply_conf_from_argv(kv)
                    end
                end

                def roby_autoload_orogen_projects
                    (models_path / "orogen").glob("*.rb").each do |extension_file|
                        project_name = extension_file.sub_ext("").basename.to_s
                        if roby_app.default_loader.has_project?(project_name)
                            begin
                                roby_app.using_task_library project_name
                            rescue StandardError # rubocop:disable Lint/SuppressedException
                            end
                        end
                    end
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

                    exclude = options[:exclude] || []
                    Doc.each_model_file_for_robot(
                        models_path, robot_names, robots: roby_app.robots
                    ) do |path|
                        next if exclude.any? { |pattern| path.fnmatch?(pattern) }

                        yield(path)
                    end
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
