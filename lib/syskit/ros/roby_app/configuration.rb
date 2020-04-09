# frozen_string_literal: true

module Syskit
    module ROS
        module Configuration
            # Add all the rosnodes defined and used in the given launch file
            # and associated oroGen projects
            #
            # @return the ROS::Nodes in use
            def use_ros_launchers_from(project_name, options = {})
                use_deployments_from(project_name, Hash[:on => "ros"].merge(options))
            end

            # Add the given launcher (referred to by its process name, that is
            # the name given in the oroGen file) to the set of deployments the
            # engine can use.
            #
            # @option options [String] :on (localhost) the name of the process
            #   server on which this deployment should be started
            def use_ros_launcher(*names)
                unless names.last.kind_of?(Hash)
                    names << ({})
                end
                names[-1] = Hash[:on => "ros"].merge(names[-1])
                use_deployment(*names)
            end
        end
    end
end

Syskit::RobyApp::Configuration.include Syskit::ROS::Configuration
