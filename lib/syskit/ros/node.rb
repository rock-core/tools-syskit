module Syskit
    module ROS
        class Node < TaskContext
            extend Logger::Hierarchy
            include Logger::Hierarchy

            def initialize(arguments = Hash.new)
                super
            end



            def needs_reconfiguration?
                false
            end

            def reusable?
                true
            end

            def prepare_for_setup(state = :RUNNING)
                true
            end

            def needs_reconfiguration!
                # n/a for ROS node
            end

            def reusable?
                # ROS node do not change configuration -- remain always running
                true
            end

            def is_setup!
                @setup = true
            end

            def setup
                if Orocos::ROS.rosnode_running?(orogen_model.ros_name)
                    is_setup!
                else
                    raise InternalError, "#setup called but ROS node '#{name}' is not running"
                end
            end

            event :start do |context|
            end

            def configure
                # n/a for ROS node
            end

            def apply_configuration(config_type)
                # n/a for ROS node
            end

        end
    end
end
