require 'roby/app/gen'
class OrogenconfGenerator < Roby::App::GenBase
    attr_reader :orogen_model_name
    # The task model
    attr_reader :task_model
    # The name of a robot-specific configuration folder
    attr_reader :robot_name

    def initialize(runtime_args, runtime_options = Hash.new)
        # Setup the robot options. Note that its usage is directly handled by
        # GenBase
        options = OptionParser.new do |opt|
            opt.on '--robot=ROBOT', '-r=ROBOT', String, "a robot name into which to generate the config file" do |name|
                @robot_name = name
            end
        end

        model_name = options.parse(runtime_args).first
        @orogen_model_name = model_name
        Roby.app.using_task_library(model_name.split('::').first)
        @task_model = Syskit::TaskContext.find_model_from_orogen_name(model_name)
        if !@task_model
            raise ArgumentError, "cannot find a task model called #{model_name}"
        end
        super
    end

    def generate_marshalled_section(section, orogen_task_model)
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

    def manifest
        record do |m|
            subdir = resolve_robot_in_path("config/orogen/ROBOT")
            m.directory subdir
            file_name     = "#{subdir}/#{task_model.orogen_model.name}.yml"
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
            end

            if !section
                Roby.warn "failed to start a component of model #{task_model.orogen_model.name}, will create the configuration file from the orogen model"
                raise NotImplementedError
            end

            content = generate_marshalled_section(section, task_model.orogen_model)
            m.add_template_to_file('conf.yml', file_name,
                                   assigns: Hash['section_name' => section_name, 'content' => content])
        end
    end
end

