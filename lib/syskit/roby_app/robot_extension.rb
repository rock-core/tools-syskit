module Syskit
    module RobyApp
        # Extensions to Roby's main Robot object
        module RobotExtension
            def each_device(&block)
                Roby.app.syskit_engine.robot.devices.each_value(&block)
            end

            def devices(&block)
                if block
                    Roby.app.syskit_engine.robot.instance_eval(&block)
                else
                    each_device
                end
            end
        end
    end
end

