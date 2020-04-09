# frozen_string_literal: true

require "roby/cli/gen_main"
require "roby/cli/exceptions"

module Syskit
    module CLI
        class GenMain < Roby::CLI::GenMain
            namespace :gen
            source_paths << File.join(__dir__, "gen")

            no_commands do
                def gen_common(template, name, category, namespace, with_tests: true)
                    Roby.app.require_app_dir(needs_current: true)
                    Roby.app.load_base_config

                    file_name, class_name = Roby::CLI::Gen.resolve_name(
                        template, name, options[:robot],
                        ["models", *category], [*namespace]
                    )

                    relative_path_wo_ext = File.join("models", *category, *file_name)

                    template File.join(template, "class.rb"),
                             "#{relative_path_wo_ext}.rb",
                             context: Roby::CLI::Gen.make_context(
                                 "class_name" => class_name
                             )

                    return unless with_tests

                    template File.join(template, "test.rb"),
                             File.join("test", *category, *file_name[0..-2],
                                       "test_#{file_name[-1]}.rb"),
                             context: Roby::CLI::Gen.make_context(
                                 "class_name" => class_name,
                                 "require_path" => relative_path_wo_ext
                             )
                end
            end

            def app(dir = nil)
                dir = super(dir, init_path: "syskit_app")

                directory "syskit_app/",
                          File.join(dir),
                          verbose: !options[:quiet]
                dir
            end

            desc "bus NAME", "generate a new bus model"
            long_desc <<~BUS_DESCRIPTION
                Generates a new communication bus model. The argument is the name of the bus
                type, either in CamelCase or in snake_case form. It can be prefixed with
                namespace(s) in/this/form or In::This::Form. It is not necessary to add the
                bundle namespace in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                syskit gen bus schilling_dts

                will generate a RockAuv::Devices::Bus::ShillingDts data service in
                models/devices/bus/shilling_dts.rb.
            BUS_DESCRIPTION
            option :robot, aliases: "r",
                           desc: "the robot name for robot-specific scaffolding",
                           type: :string, default: nil
            def bus(name)
                gen_common("bus", name, "devices", %w[Devices])
            end

            desc "dev NAME", "generate a new device model"
            long_desc <<~DEV_DESCRIPTION
                Generates a new device model. The argument is the name of the model, either in
                CamelCase or in snake_case form. It can be prefixed with namespace(s)
                in/this/form or In::This::Form. It is not necessary to add the bundle namespace
                in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                roby gen dev sonars/tritech/gemini720i

                will generate a RockAuv::Devices::Sonars::Tritech::Gemini720i device type in
                models/devices/tritech/gemini720i.rb. No test file are generated as there is
                nothing to test in a device
            DEV_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def dev(name)
                gen_common("dev", name, "devices", %w[Devices])
            end

            desc "cmp NAME", "generate a new composition model"
            long_desc <<-CMP_DESCRIPTION
                Generates a new composition (a subclass of Syskit::Composition).
                The argument is the name of the composition class, either in
                CamelCase or in snake_case form. It can be prefixed with namespace(s)
                in/this/form or In::This::Form. It is not necessary to add the bundle namespace
                in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                  roby gen cmp sensing/localization

                will generate a RockAuv::Compositions::Sensing::Localization composition in
                models/compositions/sensing/localization.rb, and the associated
                test template in test/compositions/sensing/test_localization.rb.
            CMP_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def cmp(name)
                gen_common("cmp", name, "compositions", "Compositions")
            end

            desc "ruby-task NAME", "generate a new ruby task context"
            long_desc <<~RUBY_TASK_DESCRIPTION
                Generates a new ruby task context (a subclass of Syskit::RubyTaskContext).
                The argument is the name of the composition class, either in
                CamelCase or in snake_case form. It can be prefixed with namespace(s)
                in/this/form or In::This::Form. It is not necessary to add the bundle namespace
                in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                  roby gen cmp sensing/position_generator

                  will generate a RockAuv::Compositions::Sensing::PositionGenerator ruby task in
                  models/compositions/sensing/position_generator.rb, and the associated
                  test template in test/compositions/sensing/test_position_generator.rb.
            RUBY_TASK_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def ruby_task(name)
                gen_common("ruby_task", name, "compositions", "Compositions")
            end

            desc "srv NAME", "generate a new data service"
            long_desc <<~SRV_DESCRIPTION
                Generates a new data service. The argument is the name of the service, either in
                CamelCase or in snake_case form. It can be prefixed with namespace(s)
                in/this/form or In::This::Form. It is not necessary to add the bundle namespace
                in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                  roby gen srv sensors/depth

                  will generate a RockAuv::Services::Sensors::Depth data service in
                  models/services/sensors/depth.rb. No test file are generated as there is
                  nothing to test in a data service
            SRV_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def srv(name)
                gen_common("srv", name, "services", "Services", with_tests: false)
            end

            desc "profile NAME", "generate a new profile model"
            long_desc <<-PROFILE_DESCRIPTION
                Generates a new profile.

                The argument is the name of the profile, either in CamelCase or in snake_case
                form. It can be prefixed with namespace(s) in/this/form or In::This::Form. It is
                not necessary to add the bundle namespace in front (it gets added automatically)

                Example: running the following command in a rock_auv app
                  roby gen profile sensing/localization

                  will generate a RockAuv::Profiles::Sensing::Localization profile in
                  models/profiles/sensing/localization.rb, and the associated
                  test template in test/profiles/sensing/test_localization.rb.
            PROFILE_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def profile(name)
                gen_common("profile", name, "profiles", "Profiles")
            end

            desc "orogen PROJECT_NAME", "generate an extension file for the tasks "\
                                        "of an oroGen project"
            long_desc <<~OROGEN_DESCRIPTION
                Generates a new extension file for an oroGen project. It must be given the name
                of the oroGen project as argument.

                Example: running the following command in a rock_auv app
                  roby gen orogen auv_control

                  will create a template extension file in models/orogen/auv_control.rb, which
                  already contains the definitions of the tasks found in the auv_control oroGen
                  project. It also generates an associated test file in
                  test/orogen/test_auv_control.rb.
            OROGEN_DESCRIPTION
            def orogen(project_name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.single = true
                Roby.app.base_setup
                Syskit.conf.only_load_models = true
                Roby.app.setup

                project = Roby.app.using_task_library(project_name)
                orogen_models = project.self_tasks.values
                template File.join("orogen/class.rb"),
                         File.join(Roby.app.app_dir, "models", "orogen",
                                   "#{project_name}.rb"),
                         context: Roby::CLI::Gen.make_context(
                             "orogen_project_name" => project_name,
                             "orogen_models" => orogen_models
                         )
                template File.join("orogen/test.rb"),
                         File.join(Roby.app.app_dir, "test", "orogen",
                                   "test_#{project_name}.rb"),
                         context: Roby::CLI::Gen.make_context(
                             "orogen_project_name" => project_name,
                             "orogen_models" => orogen_models
                         )
            ensure
                Roby.app.cleanup
                Roby.app.base_cleanup
            end

            no_commands do
                def orogenconf_generate_section(section, orogen_task_model)
                    section.keys.sort.flat_map do |property_name|
                        doc = "# no documentation available for this property"
                        if (pdoc = orogen_task_model.find_property(property_name)&.doc)
                            doc = pdoc.split("\n").map { |s| "# #{s}" }.join("\n")
                        end

                        property_hash = { property_name => section[property_name] }
                        yaml = YAML.dump(property_hash)
                        [doc, yaml.split("\n")[1..-1].join("\n")]
                    end.join("\n")
                end
            end

            desc "orogenconf COMPONENT_MODEL_NAME",
                 "generate a configuration file for a given component model"
            long_desc <<~OROGENCONF_DESCRIPTION
                Generates a new section into an OroGen configuration file

                If a robot name is provided with `-r`, the configuration file will be saved
                in the corresponding robot-specific folder within config/orogen/

                Example: running the following command in a rock_auv app
                  roby gen orogen-conf auv_control::AccelerationControllerTask

                  will create a new 'default' section in
                  config/orogen/auv_control::AccelerationControllerTask.yml
            OROGENCONF_DESCRIPTION
            option :robot, aliases: "r", type: :string, default: nil,
                           desc: "the robot name for robot-specific scaffolding"
            def orogenconf(model_name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                Roby.app.using_task_library(model_name.split("::").first)
                task_model = Syskit::TaskContext.find_model_from_orogen_name(model_name)
                unless task_model
                    raise Roby::CLI::CLIInvalidArguments,
                          "cannot find a task model called #{model_name}"
                end

                file_name = File.join("config", "orogen", *options[:robot],
                                      "#{task_model.orogen_model.name}.yml")
                section_name = "default"

                section = nil
                begin
                    Orocos.run task_model.orogen_model => "oroconf_extract",
                               oro_logfile: "/dev/null" do
                        task = Orocos.get "oroconf_extract"
                        task_model.configuration_manager.extract(section_name, task)
                        section = task_model.configuration_manager.conf(section_name)
                        section = Orocos::TaskConfigurations.to_yaml(section)
                    end
                rescue RuntimeError
                    unless section
                        raise Roby::CLI::CLICommandFailed,
                              "failed to start a component of model "\
                              "#{task_model.orogen_model.name}, cannot create "\
                              "a configuration file with default values"
                    end
                end

                return unless section

                content = orogenconf_generate_section(section, task_model.orogen_model)
                template File.join("orogenconf", "conf.yml"), file_name,
                         context: Roby::CLI::Gen.make_context(
                             "section_name" => section_name,
                             "content" => content
                         )
            end
        end
    end
end
