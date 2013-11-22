module Syskit
    module ROS
        module Configuration
            # Add all the rosnodes defined and used in the given launch file
            # and associated oroGen projects
            #
            # @return the ROS::Nodes in use
            def use_ros_launchers_from(project_name, options = Hash.new)
                project = Roby.app.using_ros_package(project_name)
                if project.ros_launchers.empty?
                    raise ArgumentError, "Syskit::ROS: did not find any launchers for project: '#{project_name}'. Search dirs: #{Orocos::ROS.spec_search_directories.join(",")}"
                end

                project.ros_launchers.each do |launcher|
                    use_ros_launcher(launcher.name, options)
                end
            end


            # Add the given launcher (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            def use_ros_launcher(*names)
                if !names.last.kind_of?(Hash)
                    names << Hash.new
                end

                new_launchers, options = Orocos::ROS::LauncherProcess.parse_run_options(*names)

                options, run_options = Kernel.validate_options names.last, :on => 'ros'

                new_launchers.each do |launcher_name|
                    model = app.using_ros_launcher(launcher_name, options)

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
