require 'roby/app/gen'

class OrogenGenerator < Roby::App::GenBase
    attr_reader :project_name
    attr_reader :project
    attr_reader :orogen_models

    def initialize(runtime_args, runtime_options = Hash.new)
        super
        @project_name = runtime_args.shift
        @project = Roby.app.using_task_library(project_name)
        @orogen_models = project.self_tasks.values
    end
    
    def manifest
        record do |m|
            subdir = "ROBOT/orogen"
            m.directory "models/#{subdir}"
            m.directory "test/#{subdir}"
            local_vars = Hash[
                'orogen_models' => orogen_models,
                'orogen_project_name' => project_name]
            m.template 'class.rb', "models/#{subdir}/#{project_name}.rb", :assigns => local_vars
            m.template 'test.rb', "test/#{subdir}/test_#{project_name}.rb", :assigns => local_vars
        end
    end
end

