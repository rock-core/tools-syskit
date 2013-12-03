require 'roby/app/gen'
class OrogenGenerator < Roby::App::GenBase
    attr_reader :project_name
    attr_reader :project
    attr_reader :classes
    attr_reader :orogen_project_module_name

    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = "orogen"
        super
        @project_name = runtime_args.shift
        @project = Roby.app.using_task_library(project_name)
        @classes = Array.new
        project.self_tasks.each_value do |orogen_task|
            classes << Syskit::TaskContext.syskit_names_from_orogen_name(orogen_task.name)
        end
        @orogen_project_module_name = project_name.camelcase(:upper)
    end
    
    def manifest
        record do |m|
            subdir = "ROBOT/orogen"
            m.directory "models/#{subdir}"
            m.directory "test/#{subdir}"
            local_vars = Hash[
                'classes' => classes,
                'orogen_project_name' => project_name,
                'orogen_project_module_name' => orogen_project_module_name]
            m.template 'class.rb', "models/#{subdir}/#{project_name}.rb", :assigns => local_vars
            m.template 'test.rb', "test/#{subdir}/test_#{project_name}.rb", :assigns => local_vars
            register_in_aggregate_require_files(m, "require_file.rb", "test/#{subdir}/test_#{project_name}.rb", "test", "suite_%s.rb")
        end
    end
end

