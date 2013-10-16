module Syskit
    module RobyApp
        class Configuration < Roby::OpenStruct

            attr_reader :ros_launchers

            attr_reader :ros_nodes

            # Add all the rosnodes defined and used in the given launch file
            # and associated oroGen projects
            #
            # @return the ROS::Nodes in use
            def use_rosnodes_from(project_name, options = Hash.new)
                Syskit.info "using rosnodes from project #{project_name}"
                orogen = Roby.app.load_ros_project(project_name, options)

                @launchers.merge!(orogen.ros_launchers)

                result = []
                orogen.ros_launchers.each do |launcher_def|
                    result << launcher_def.nodes
                end
                result.flatten
            end

            def use_rosnode(*names)
                model = Deployment
                

            end
        end
    end
end
