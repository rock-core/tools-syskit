module Orocos
    module RobyPlugin
        # This gets mixed in Roby::Application when the orocos plugin is loaded.
        # It adds the configuration facilities needed to plug-in orogen projects
        # in Roby.
        module Application
            # The set of loaded orogen projects. See #load_orogen_project.
            attribute(:loaded_orogen_projects) { Hash.new }
            # A mapping from task context model name to the corresponding
            # subclass of Orocos::RobyPlugin::TaskContext
            attribute(:orocos_tasks) { Hash.new }
            # A mapping from deployment name to the corresponding
            # subclass of Orocos::RobyPlugin::Deployment
            attribute(:orocos_deployments) { Hash.new }
            # A mapping from device type to the corresponding submodel of
            # DeviceDriver
            attribute(:orocos_data_sources) { Hash.new }
            # A mapping from device type to the corresponding submodel of
            # DeviceDriver
            attribute(:orocos_devices) { Hash.new }
            # A mapping from name to the corresponding subclass of Composition
            attribute(:orocos_compositions) { Hash.new }

            # Returns true if the given orogen project has already been loaded
            # by #load_orogen_project
            def loaded_orogen_project?(name); loaded_orogen_projects.include?(name) end
            # Load the given orogen project and defines the associated task
            # models. It also loads the projects this one depends on.
            def load_orogen_project(name)
                return if loaded_orogen_project?(name)

                orogen = Orocos::Generation.load_task_library(name)
		Orocos.registry.merge(orogen.registry)
                loaded_orogen_projects[name] = orogen

                orogen.tasks.each do |task_def|
                    if !orocos_tasks[task_def.name]
                        orocos_tasks[task_def.name] = Orocos::RobyPlugin::TaskContext.define_from_orogen(task_def)
                    end
                end
                orogen.deployers.each do |deployment_def|
                    if deployment_def.install? && !orocos_deployments[deployment_def.name]
                        orocos_deployments[deployment_def.name] = Orocos::RobyPlugin::Deployment.define_from_orogen(deployment_def)
                    end
                end
            end

            def orogen_load_all
                Orocos.available_projects.each_key do |name|
                    load_orogen_project(name)
                end
            end

            def self.setup
                Roby.app.orocos_clear_models
                Roby.app.orocos_tasks['RTT::TaskContext'] = Orocos::RobyPlugin::TaskContext

                rtt_taskmodel = Orocos::Generation::Component.standard_tasks.
                    find { |m| m.name == "RTT::TaskContext" }
                Orocos::RobyPlugin::TaskContext.instance_variable_set :@orogen_spec, rtt_taskmodel
                Orocos::RobyPlugin.const_set :RTT, Module.new
                Orocos::RobyPlugin::RTT.const_set :TaskContext, Orocos::RobyPlugin::TaskContext
            end

            def orocos_clear_models
                projects = Set.new
                orocos_compositions.each_value do |model|
                    task_name    = model.name.camelcase(true)
                    constant("Orocos::RobyPlugin::Compositions").send(:remove_const, task_name)
                end
                orocos_compositions.clear

                orocos_tasks.each_value do |model|
                    if model.orogen_spec
                        project_name = model.orogen_spec.component.name.camelcase(true)
                        task_name    = model.orogen_spec.basename.camelcase(true)
                        projects << project_name
                        constant("Orocos::RobyPlugin::#{project_name}").send(:remove_const, task_name)
                    end
                end
                orocos_tasks.clear

                orocos_deployments.each_key do |name|
                    name = name.camelcase(true)
                    Orocos::RobyPlugin::Deployments.send(:remove_const, name)
                end
                orocos_deployments.clear

                projects.each do |name|
                    name = name.camelcase(true)
                    Orocos::RobyPlugin.send(:remove_const, name)
                end

                orocos_devices.clear
                orocos_data_sources.clear
            end

            def self.run(app)
                Orocos.initialize
                Roby.each_cycle(&Orocos.update)
            end
        end
    end

    Roby::Application.register_plugin('orocos', Orocos::RobyPlugin::Application) do
        require 'orocos/roby'
    end
end

