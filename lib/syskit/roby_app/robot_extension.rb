module Syskit
    module RobyApp
        # Extensions to Roby's main Robot object
        module RobotExtension
            def each_device(&block)
                Roby.app.syskit_engine.robot.devices.each_value(&block)
            end

            def devices(&block)
                if block
                    Kernel.dsl_exec(Roby.app.syskit_engine.robot, Syskit.constant_search_path, !Roby.app.filter_backtraces?, &block)
                    Roby.app.syskit_engine.export_devices_to_planner(::MainPlanner)
                else
                    each_device
                end
            end
        end
    end
end

