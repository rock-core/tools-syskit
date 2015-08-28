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
                profile.robot.each_master_device do |dev|
                    action_name = "#{dev.name}_dev"
                    if !actions[action_name]
                        req = dev.to_instance_requirements
                        profile.inject_di_context(req)
                        actions[action_name] = Models::Action.new(self, req, dev.doc || "device from profile #{profile.name}")
                        actions[action_name].name = action_name
                        actions[action_name].advanced = dev.advanced?
                        define_method(action_name) do
                            model.find_action_by_name(action_name).as_plan
                        end
                    end
                end

                profile.definitions.each do |name, req|
                    action_name = "#{name}_def"
                    advanced    = req.advanced?

                    req = profile.resolved_definition(name)
                    action_model = Models::Action.new(self, req, req.doc || "definition from profile #{profile.name}")
                    action_model.name = action_name
                    action_model.advanced = advanced

                    task_model = req.component_model
                    root_model = [Syskit::TaskContext, Syskit::Composition, Syskit::Component].find { |m| task_model <= m }
                    task_arguments = task_model.arguments.to_a - root_model.arguments.to_a

                    has_required_arguments = false
                    task_arguments.each do |arg_name|
                        if task_model.default_argument(arg_name) || req.arguments.has_key?(arg_name.to_s)
                            action_model.optional_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                        else
                            has_required_arguments = true
                            action_model.required_arg(arg_name, "#{arg_name} argument of #{task_model.name}")
                        end
                    end

                    actions[action_name] = action_model
                    if has_required_arguments
                        define_method(action_name) do |arguments|
                            final_req = model.find_action_by_name(action_name).to_instance_requirements.dup
                            final_req.with_arguments(arguments)
                            final_req.as_plan
                        end
                    elsif !task_arguments.empty?
                        define_method(action_name) do |arguments = Hash.new|
                            final_req = model.find_action_by_name(action_name).to_instance_requirements.dup
                            final_req.with_arguments(arguments)
                            final_req.as_plan
                        end
                    else
                        define_method(action_name) do
                            model.find_action_by_name(action_name).as_plan
                        end
                    end
                end
            end
        end
        Roby::Actions::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension
    end
end

