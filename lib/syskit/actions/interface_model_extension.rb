module Syskit
    module Actions
        # Extension to the models of Roby::Actions::Interface
        module LibraryExtension
            # The main Syskit::Actions::Profile object that is used in an
            # action interface
            def profile(name = nil, &block)
                return super if name

                if !@profile
                    @profile = super("Profile") { self }
                    setup_main_profile(@profile)
                end

                if block
                    Roby.warn_deprecated "calling profile do ... end in an action interface is deprecated, call use_profile do .. end instead"
                    use_profile(&block)
                else
                    @profile
                end
            end

            def setup_main_profile(profile)
            end

            # Define on self tags that match the profile's tags
            def use_profile_tags(profile)
                tag_map = Hash.new
                profile.each_tag do |tag|
                    tagged_models = [*tag.proxied_data_services]
                    tag_map[tag.tag_name] = @profile.tag(tag.tag_name, *tagged_models)
                end
                tag_map
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
            def use_profile(used_profile = nil, tag_selection = Hash.new, transform_names: ->(name) { name })
                if block_given?
                    if !tag_selection.empty?
                        raise ArgumentError, "cannot provide a tag selection when defining a new anonymous profile"
                    end

                    used_profile = Profile.new("#{self.name}::<anonymous>", register: true)
                    used_profile.instance_eval(&proc)
                    tag_selection = use_profile_tags(used_profile)
                elsif !used_profile
                    raise ArgumentError, "must provide either a profile object or a block"
                end

                @current_description = nil
                new_definitions =
                    profile.use_profile(used_profile, tag_selection, transform_names: transform_names)
                new_definitions.each do |definition|
                    register_action_from_profile(definition.to_action_model)
                end
            end

            def find_through_method_missing(m, args, call: true)
                MetaRuby::DSLs.find_through_method_missing(
                    profile, m, args, 'tag' => :find_tag, call: call) || super
            end

            def respond_to_missing?(m, include_private)
                !!find_through_method_missing(m, [], call: false) || super
            end

            def method_missing(m, *args, &block)
                find_through_method_missing(m, args) || super
            end
        end

        module InterfaceModelExtension
            def setup_main_profile(profile)
                super
                if superclass.kind_of?(InterfaceModelExtension)
                    tag_map = use_profile_tags(superclass.profile)
                    profile.use_profile(superclass.profile, tag_map)
                end
            end
        end

        Roby::Actions::Models::Library.include LibraryExtension
        Roby::Actions::Interface.extend LibraryExtension
        Roby::Actions::Interface.extend InterfaceModelExtension

        module InterfaceExtension
            def profile
                self.class.profile
            end

            def find_through_method_missing(m, args, call: true)
                MetaRuby::DSLs.find_through_method_missing(
                    profile, m, args, 'tag' => :find_tag, call: call) || super
            end

            def respond_to_missing?(m, include_private)
                !!find_through_method_missing(m, [], call: false) || super
            end

            def method_missing(m, *args, &block)
                find_through_method_missing(m, args) || super
            end
        end
        Roby::Actions::Interface.include InterfaceExtension
    end
end

