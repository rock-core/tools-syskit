module Syskit
    module ROS
        class Node < TaskContext
            extend Logger::Hierarchy
            include Logger::Hierarchy

            def initialize(arguments = Hash.new)
                super
            end

            def prepare_for_setup(state = nil)
                true
            end

            def ready_for_setup?(state = nil)
                super(:PRE_OPERATIONAL)
            end

            def setup
                if Orocos::ROS.rosnode_running?(orocos_name)
                    is_setup!
                else
                    raise InternalError, "#setup called but ROS node '#{orocos_name}' is not running"
                end
            end

            def needs_reconfiguration!
                raise NotImplementedError, "cannot reconfigure a Syskit::ROS::Node"
            end

            event :start do |context|
                emit :start
            end

            event :stop do |context|
                emit :stop
            end

            def update_orogen_state
            end

            def configure
            end
        end
    end
end

