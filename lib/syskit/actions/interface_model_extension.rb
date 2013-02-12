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
                @current_description = nil
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
                        action_model = ActionModel.new(self, req, "definition from profile #{profile.name}")
                        action_model.name = action_name
                        if task_model = req.find_model_by_type(Roby::Task)
                            task_model.arguments.each do |arg_name|
                                if task_model.default_argument(arg_name) || req.arguments.has_key?(arg_name.to_s)
                                    action_model.optional_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                                else
                                    action_model.required_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                                end
                            end
                        end

                        actions[action_name] = action_model
                        if task_model && !task_model.arguments.empty?
                            define_method(action_name) do |arguments|
                                final_req = req.dup
                                final_req.with_arguments(arguments)
                                final_req.as_plan
                            end
                        else
                            define_method(action_name) do
                                req.as_plan
                            end
                        end
                    end
                end
            end
        end
        Roby::Actions::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension
    end
end

