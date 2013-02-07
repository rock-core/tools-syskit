module Syskit
    module Actions
        # Extension to the models of Roby::Actions::Interface
        module InterfaceModelExtension
            # The main Syskit::Actions::Profile object that is used in an
            # action interface
            attribute(:main_profile) { Syskit::Actions::Profile.new }

            # Returns the robot definition object used by this action interface
            # @return [Syskit::Robot::RobotDefinition]
            def robot; main_profile.robot end

            # Export the definitions contained in the given profile as actions
            # on this action interface
            #
            # @param [String,SyskitProfile] the profile that should be used
            # @return [void]
            def use_profile(profile)
                main_profile.use_profile(profile)
                profile.robot.devices.each do |name, dev|
                    action_name = "#{name}_dev"
                    if !actions[action_name]
                        req = dev.to_instance_requirements
                        profile.inject_di_context(req)
                        actions[action_name] = ActionModel.new(self, req, "device from profile #{profile.name}")
                        actions[action_name].name = action_name
                        define_method(action_name) do
                            req.as_plan
                        end
                    end
                end

                profile.definitions.each do |name, req|
                    action_name = "#{name}_def"
                    if !actions[action_name]
                        req = profile.resolved_definition(name)
                        actions[action_name] = ActionModel.new(self, req, "definition from profile #{profile.name}")
                        actions[action_name].name = action_name
                        define_method(action_name) do
                            req.as_plan
                        end
                    end
                end
            end
        end
        Roby::Actions::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension
    end
end

