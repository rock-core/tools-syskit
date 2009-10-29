module Roby
    module Orocos
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Application
            # The set of loaded orogen projects. See #load_orogen_project.
            attribute(:loaded_orogen_projects) { Hash.new }
            # A mapping from task context model name to the corresponding
            # subclass of Roby::Orocos::TaskContext
            attribute(:orocos_tasks) { Hash.new }
            # A mapping from deployment name to the corresponding
            # subclass of Roby::Orocos::Deployment
            attribute(:orocos_deployments) { Hash.new }
            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.include?(name) end
            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            def load_orogen_project(name)
                return if loaded_orogen_project?(name)

                orogen = Orocos::Generation.load_task_library(name)
                loaded_orogen_projects[name] = orogen

                orogen.tasks.each do |task_def|
                    if !orocos_tasks[task_def.name]
                        orocos_tasks[task_def.name] = Roby::Orocos::TaskContext.define_from_orogen(task_def)
                    end
                end
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install? && !orocos_deployments[deployment_def.name]
                        orocos_deployments[deployment_def.name] = Roby::Orocos::Deployment.define_from_orogen(deployment_def)
                    end
                end
            end

            def orocos_clear_models
                projects = Set.new
                orocos_tasks.each_value do |model|
                    project_name = model.orogen_spec.component.name.camelcase(true)
                    task_name    = model.orogen_spec.basename.camelcase(true)
                    projects << project_name
                    constant("Roby::Orocos::#{project_name}").send(:remove_const, task_name)
                end
                orocos_tasks.clear

                orocos_deployments.each_key do |name|
                    name = name.camelcase(true)
                    Roby::Orocos::Deployments.send(:remove_const, name)
                end

                projects.each do |name|
                    name = name.camelcase(true)
                    Roby::Orocos.send(:remove_const, name)
                end
            end

            def self.run(app)
                Roby.each_cycle(&Orocos.update)
            end
        end
    end

    Application.register_plugin('orocos', Roby::Orocos::Application) do
        require 'roby-orocos'
    end
end

