require 'roby/cli/gen_main'
require 'roby/cli/exceptions'

module Syskit
    module CLI
        class GenMain < Roby::CLI::GenMain
            namespace :gen
            source_paths << File.join(__dir__, 'gen')

            def app(dir = nil)
                dir = super(dir, init_path: 'syskit_app')

                directory 'syskit_app/', File.join(dir),
                    verbose: !options[:quiet]
                dir
            end

            desc 'bus NAME', "generate a new bus model"
            long_desc <<-EOD
Generates a new communication bus model. The argument is the name of the bus
type, either in CamelCase or in snake_case form. It can be prefixed with
namespace(s) in/this/form or In::This::Form. It is not necessary to add the
bundle namespace in front (it gets added automatically)

Example: running the following command in a rock_auv app
  syskit gen bus schilling_dts

  will generate a RockAuv::Devices::Bus::ShillingDts data service in
  models/devices/bus/shilling_dts.rb.
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def bus(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'bus', name, options[:robot], ['models', 'devices'], ["Devices"])

                template File.join('bus', 'class.rb'),
                    File.join('models', 'devices', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('bus_name' => class_name)
                template File.join('bus', "test.rb"),
                    File.join('test', 'devices', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'bus_name' => class_name,
                        'require_path' => File.join('models', "devices", *file_name))
            end

            desc 'dev NAME', "generate a new device model"
            long_desc <<-EOD
Generates a new device model. The argument is the name of the model, either in
CamelCase or in snake_case form. It can be prefixed with namespace(s)
in/this/form or In::This::Form. It is not necessary to add the bundle namespace
in front (it gets added automatically)

Example: running the following command in a rock_auv app
  roby gen dev sonars/tritech/gemini720i

  will generate a RockAuv::Devices::Sonars::Tritech::Gemini720i device type in
  models/devices/tritech/gemini720i.rb. No test file are generated as there is
  nothing to test in a device
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def dev(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'device', name, options[:robot], ['models', 'devices'], ["Devices"])

                template File.join('dev', 'class.rb'),
                    File.join('models', 'devices', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('dev_name' => class_name)
                template File.join('dev', "test.rb"),
                    File.join('test', 'devices', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'dev_name' => class_name,
                        'require_path' => File.join('models', "devices", *file_name))
            end

            desc 'cmp NAME', "generate a new composition model"
            long_desc <<-EOD
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
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def cmp(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'composition', name, options[:robot], ['models', 'compositions'], ["Compositions"])

                template File.join('cmp', 'class.rb'),
                    File.join('models', 'compositions', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('class_name' => class_name)
                template File.join('cmp', "test.rb"),
                    File.join('test', 'compositions', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join('models', "compositions", *file_name))
            end

            desc 'ruby-task NAME', "generate a new ruby task context"
            long_desc <<-EOD
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
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def ruby_task(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'ruby task', name, options[:robot], ['models', 'compositions'], ["Compositions"])

                template File.join('ruby_task', 'class.rb'),
                    File.join('models', 'compositions', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('class_name' => class_name)
                template File.join('ruby_task', "test.rb"),
                    File.join('test', 'compositions', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join('models', "compositions", *file_name))
            end

            desc 'srv NAME', "generate a new data service"
            long_desc <<-EOD
Generates a new data service. The argument is the name of the service, either in
CamelCase or in snake_case form. It can be prefixed with namespace(s)
in/this/form or In::This::Form. It is not necessary to add the bundle namespace
in front (it gets added automatically)

Example: running the following command in a rock_auv app
  roby gen srv sensors/depth

  will generate a RockAuv::Services::Sensors::Depth data service in
  models/services/sensors/depth.rb. No test file are generated as there is
  nothing to test in a data service
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def srv(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'service', name, options[:robot], ['models', 'services'], ["Services"])

                template File.join('srv', 'class.rb'),
                    File.join('models', 'services', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('class_name' => class_name)
            end

            desc 'profile NAME', "generate a new profile model"
            long_desc <<-EOD
Generates a new profile.

The argument is the name of the profile, either in CamelCase or in snake_case
form. It can be prefixed with namespace(s) in/this/form or In::This::Form. It is
not necessary to add the bundle namespace in front (it gets added automatically)

Example: running the following command in a rock_auv app
  roby gen profile sensing/localization

  will generate a RockAuv::Profiles::Sensing::Localization profile in
  models/profiles/sensing/localization.rb, and the associated
  test template in test/profiles/sensing/test_localization.rb.
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def profile(name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                file_name, class_name = Roby::CLI::Gen.resolve_name(
                    'profile', name, options[:robot], ['models', 'profiles'], ["Profiles"])

                template File.join('profile', 'class.rb'),
                    File.join('models', 'profiles', *file_name) + ".rb",
                    context: Roby::CLI::Gen.make_context('class_name' => class_name)
                template File.join('profile', "test.rb"),
                    File.join('test', 'profiles', *file_name[0..-2], "test_#{file_name[-1]}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'class_name' => class_name,
                        'require_path' => File.join('models', "profiles", *file_name))
            end

            desc 'orogen PROJECT_NAME', "generate an extension file for the tasks of an oroGen project"
            long_desc <<-EOD
Generates a new extension file for an oroGen project. It must be given the name
of the oroGen project as argument.

Example: running the following command in a rock_auv app
  roby gen orogen auv_control

  will create a template extension file in models/orogen/auv_control.rb, which
  already contains the definitions of the tasks found in the auv_control oroGen
  project. It also generates an associated test file in
  test/orogen/test_auv_control.rb.
            EOD
            def orogen(project_name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.single = true
                Roby.app.base_setup
                Syskit.conf.only_load_models = true
                Roby.app.setup

                project = Roby.app.using_task_library(project_name)
                orogen_models = project.self_tasks.values
                template File.join('orogen/class.rb'),
                    File.join(Roby.app.app_dir, 'models', 'orogen', "#{project_name}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'orogen_project_name' => project_name,
                        'orogen_models' => orogen_models)
                template File.join('orogen/test.rb'),
                    File.join(Roby.app.app_dir, 'test', 'orogen', "test_#{project_name}.rb"),
                    context: Roby::CLI::Gen.make_context(
                        'orogen_project_name' => project_name,
                        'orogen_models' => orogen_models)
            ensure
                Roby.app.cleanup
                Roby.app.base_cleanup
            end

            no_commands do
                def orogenconf_generate_section(section, orogen_task_model)
                    section.keys.sort.flat_map do |property_name|
                        if (p = orogen_task_model.find_property(property_name)) && (doc = p.doc)
                            doc = doc.split("\n").map { |s| "# #{s}" }.join("\n")
                        else
                            doc = "# no documentation available for this property"
                        end

                        property_hash = { property_name => section[property_name] }
                        yaml = YAML.dump(property_hash)
                        [doc, yaml.split("\n")[1..-1].join("\n")]
                    end.join("\n")
                end
            end

            desc 'orogenconf COMPONENT_MODEL_NAME', "generate a configuration file for a given component model"
            long_desc <<-EOD
Generates a new section into an OroGen configuration file

If a robot name is provided with `-r`, the configuration file will be saved
in the corresponding robot-specific folder within config/orogen/

Example: running the following command in a rock_auv app
  roby gen orogen-conf auv_control::AccelerationControllerTask

  will create a new 'default' section in
  config/orogen/auv_control::AccelerationControllerTask.yml
            EOD
            option :robot, aliases: 'r', desc: 'the robot name for robot-specific scaffolding',
                type: :string, default: nil
            def orogenconf(model_name)
                Roby.app.require_app_dir(needs_current: true)
                Roby.app.load_base_config

                orogen_model_name = model_name
                Roby.app.using_task_library(model_name.split('::').first)
                task_model = Syskit::TaskContext.find_model_from_orogen_name(model_name)
                if !task_model
                    raise Roby::CLI::CLIInvalidArguments, "cannot find a task model called #{model_name}"
                end

                file_name = File.join('config', 'orogen', *options[:robot], "#{task_model.orogen_model.name}.yml")
                section_name  = "default"

                section = nil
                begin
                    Orocos.run task_model.orogen_model => "oroconf_extract", oro_logfile: '/dev/null' do
                        task = Orocos.get "oroconf_extract"
                        task_model.configuration_manager.extract(section_name, task)
                        section = task_model.configuration_manager.conf(section_name)
                        section = Orocos::TaskConfigurations.to_yaml(section)
                    end
                rescue Exception => e
                    if !section
                        raise Roby::CLI::CLICommandFailed, "failed to start a component of model #{task_model.orogen_model.name}, cannot create a configuration file with default values"
                    end
                end

                if section
                    content = orogenconf_generate_section(section, task_model.orogen_model)
                    template File.join('orogenconf', 'conf.yml'), file_name,
                        context: Roby::CLI::Gen.make_context('section_name' => section_name, 'content' => content)
                end
            end
        end
    end
end
