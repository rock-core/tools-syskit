module Syskit
    module ROS
        module Configuration

            attr_reader :ros_launchers

            # The set of loaded orogen projects, as a mapping from the project
            # name to the corresponding TaskLibrary instance
            #
            # See #load_ros_project.
            attribute(:loaded_ros_projects) { Hash.new }

            # Returns true if the given ros project has already been loaded
            # by #load_orogen_project
            def loaded_ros_project?(name); loaded_ros_projects.has_key?(name) end

            # Add all the rosnodes defined and used in the given launch file
            # and associated oroGen projects
            #
            # @return the ROS::Nodes in use
            def use_roslaunchers_from(project_name, options = Hash.new)
                Orocos::ROS.load

                if !ros_launchers
                    @ros_launchers = Array.new
                end

                launcher_found = false
                Orocos::ROS.available_launchers.each do |name, launcher|
                    if launcher.project.name == project_name
                        @ros_launchers << launcher
                        use_roslauncher(name, options)
                        launcher_found = true
                    end
                end
                if !launcher_found
                    raise ArgumentError, "Syskit::ROS: did not find any launchers for project: '#{project_name}'. Search dirs: #{Orocos::ROS.spec_search_directories.join(",")}"
                end

                @ros_launchers
            end


            # Define project from launcher and 
            #
            # @return [Orocos::ROS::Generation::Project]
            def load_ros_project_by_name(project_name)
                if loaded_ros_project?(project_name)
                    return loaded_ros_projects[project_name] 
                end

                project,_ = Orocos::ROS.available_projects[project_name]

                project.self_tasks.each do |task_def|
                    if !TaskContext.has_model_for?(task_def)
                        Syskit::ROS::Node.define_from_orogen(task_def, :register => true)
                    end
                end

                project.ros_launchers.each do |launcher_def|
                    if !Deployment.has_model_for?(launcher_def)
                        Syskit::Deployment.define_from_orogen(launcher_def, :register => true)
                    end
                end

                Roby.app.load_component_extension(project_name)

                project
            end

            def load_launcher_model(launcher_name, options = Hash.new)
                options = Kernel.validate_options options, :on => 'localhost'
                server   = Syskit.conf.process_server_for(options[:on])
                launcher = server.load_ros_launcher(launcher_name)

                project_name = launcher.project.name
                if !loaded_ros_project?(project_name)
                    # The project was already loaded on
                    # Orocos.master_project before Roby kicked in. Just load
                    # the Roby part
                    load_ros_project_by_name(project_name)
                end

                launcher.used_task_libraries.each do |t|
                    load_ros_project_by_name(t.name)
                end

                Deployment.find_model_from_orogen_name(launcher_name)
            end

            # Add the given launcher (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            def use_roslauncher(*names)
                if !names.last.kind_of?(Hash)
                    names << Hash.new
                end

                new_launchers, options = Orocos::ROS::LauncherProcess.parse_run_options(*names)

                options, run_options = Kernel.filter_options names.last, :on
                if !options[:on]
                    raise ArgumentError, "an explicit selection of the processserver for ROS is required. Please specify the ':on' option."
                end

                new_launchers.each do |launcher_name|
                    model = load_launcher_model(launcher_name, options)

                    configured_deployment = Models::ConfiguredDeployment.new(options[:on], model)

                    configured_deployment.each_orogen_deployed_task_context_model do |task|
                        orocos_name = task.name
                        if deployed_tasks[orocos_name] && deployed_tasks[orocos_name] != configured_deployment
                            raise TaskNameAlreadyInUse.new(orocos_name, deployed_tasks[orocos_name], configured_deployment), "there is already a deployment that provides #{orocos_name}"
                        end
                    end
                    configured_deployment.each_orogen_deployed_task_context_model do |task|
                        deployed_tasks[task.name] = configured_deployment
                    end
                    deployments[options[:on]] << configured_deployment
                    configured_deployment
                end
                model
            end
        end
    end
end

Syskit::RobyApp::Configuration.include Syskit::ROS::Configuration
