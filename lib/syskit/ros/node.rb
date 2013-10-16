module Syskit
    module ROS
        class Node < TaskContext
            extend Logger::Hierarchy
            include Logger::Hierarchy

            def initialize(arguments = Hash.new)
                options, task_options = Kernel.filter_options arguments,
                    :orogen_model => nil
                super(task_options)

                @orogen_model   = options[:orogen_model] ||
                    Orocos::ROS::Spec::Node.new(nil, model.orogen_model)

                # All tasks start with executable? and setup? set to false
                #
                # Then, the engine will call setup, which will do what it should
                @setup = false
                self.executable = false
            end

            def can_merge?(other_task)
                NetworkGeneration.debug { "cannot merge #{other_task} in #{self}: #{self} does not support merging" }
                # ROS Task cannot be merged
                false
            end

            def merge(merged_task)
                raise RuntimeError, "#{self} does not support merging of task"
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
                    raise InternalError, "#setup called but ROS node '#{name}' is not running -- note that currently, ROS nodes have to permanently running to be used with syskit"
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
