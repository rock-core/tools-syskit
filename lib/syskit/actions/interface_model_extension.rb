module Syskit
    module Actions
        # Extension to the models of Roby::Actions::Interface
        module InterfaceModelExtension
            # The main Syskit::Actions::Profile object that is used in an
            # action interface
            def profile(name = nil, &block)
                return super if name

                if !@profile
                    @profile = super("Profile") { self }
                    if superclass.kind_of?(InterfaceModelExtension)
                        @profile.use_profile(superclass.profile)
                    end
                end

                if block
                    @profile.instance_eval(&block)
                else
                    @profile
                end
            end

            # @api private
            #
            # An action library that is created and included on-the-fly to
            # support the actions derived from {#profile}
            def profile_library
                if !@profile_library
                    @profile_library = Roby::Actions::Library.new_submodel
                    use_library @profile_library
                end
                @profile_library
            end

            # Returns the robot definition object used by this action interface
            # @return [Syskit::Robot::RobotDefinition]
            def robot(&block)
                existing_devices = profile.robot.each_master_device.to_a
                profile.robot(&block)
                new_devices = profile.robot.each_master_device.to_a - existing_devices
                new_devices.each do |dev|
                    register_action_from_profile(dev.to_action_model)
                end
            end

            # Define a tag on {#profile}
            def tag(name, model); profile.tag(name, model) end

            # @api private
            #
            # Registers an action that has been derived from a profile
            # definition or device
            def register_action_from_profile(action_model)
                action_model = action_model.rebind(self)
                action_name  = action_model.name
                profile_library.register_action(action_name, action_model)
                action_model = find_action_by_name(action_name)

                args = action_model.each_arg.to_a
                if args.any?(&:required?)
                    profile_library.send(:define_method, action_name) do |arguments|
                        action_model.to_instance_requirements(arguments)
                    end
                elsif !args.empty?
                    profile_library.send(:define_method, action_name) do |arguments = Hash.new|
                        action_model.to_instance_requirements(arguments)
                    end
                else
                    profile_library.send(:define_method, action_name) do
                        action_model.to_instance_requirements(Hash.new)
                    end
                end
            end

            # Export the definitions contained in the given profile as actions
            # on this action interface
            #
            # @param [Profile] used_profile the profile that should be used
            # @param [Hash] tag_selection selection for the profile tags, see
            #   {Profile#use_profile}
            # @return [void]
            def use_profile(used_profile, tag_selection = Hash.new)
                @current_description = nil
                profile.use_profile(used_profile, tag_selection)
                used_profile.each_action do |action_model|
                    register_action_from_profile(action_model)
                end
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /^(\w+)_tag$/
                    return profile.send(m, *args, &block)
                else super
                end
            end
        end
        Roby::Actions::Models::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension

        module InterfaceExtension
            def profile
                self.class.profile
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /^(\w+)_tag$/
                    tag_name = $1
                    return self.class.profile.send(m, *args, &block)
                else super
                end
            end
        end
        Roby::Actions::Interface.include InterfaceExtension
    end
end

