# frozen_string_literal: true

module Syskit
    module Actions # rubocop:disable Style/Documentation
        # Extension to the models of Roby::Actions::Interface
        module LibraryExtension
            # The main Syskit::Actions::Profile object that is used in an
            # action interface
            def profile(name = nil, &block)
                return super if name

                unless @profile
                    @profile = super("Profile") { self }
                    setup_main_profile(@profile)
                end

                if block
                    Roby.warn_deprecated(
                        "calling profile do ... end in an action interface is "\
                        "deprecated, call use_profile do .. end instead"
                    )
                    use_profile(&block)
                else
                    @profile
                end
            end

            def setup_main_profile(profile); end

            # Define on self tags that match the profile's tags
            def use_profile_tags(used_profile)
                tag_map = {}
                used_profile.each_tag do |tag|
                    tagged_models =
                        [tag.proxied_component_model, *tag.proxied_data_service_models]
                    tag_map[tag.tag_name] = profile.tag(tag.tag_name, *tagged_models)
                end
                tag_map
            end

            # @api private
            #
            # An action library that is created and included on-the-fly to
            # support the actions derived from {#profile}
            def profile_library
                unless @profile_library
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
            def tag(name, model)
                profile.tag(name, model)
            end

            # @api private
            #
            # Registers an action that has been derived from a profile
            # definition or device
            def register_action_from_profile(action_model)
                action_model = action_model.rebind(self)
                action_name  = action_model.name
                profile_library.register_action(action_name, action_model)
                action_model = find_action_by_name(action_name)

                register_action_method_from_model(action_model)
            end

            # @api private
            #
            # Return a callable that can be used to validate the arguments
            # given to an action method defined on the basis of a profile definition
            def self.argument_validator(action_model)
                action_args = action_model.each_arg.map { |a| a.name.to_sym }
                required_args = action_model
                                .each_arg.find_all(&:required?)
                                .map { |a| a.name.to_sym }

                lambda do |arguments|
                    LibraryExtension.validate_method_arguments(
                        arguments, action_args, required_args
                    )
                end
            end

            # @api private
            #
            # Actually perform the validation for {.argument_validator}
            def self.validate_method_arguments(arguments, all, required)
                required = required.dup
                arguments.each_key do |sym|
                    unless all.include?(sym)
                        raise ArgumentError, "unknown argument '#{sym}'"
                    end

                    required.delete(sym)
                end
                return if required.empty?

                missing = required.map(&:to_s).sort.join(", ")
                raise ArgumentError, "missing arguments #{missing}"
            end

            # Registers a method for an action, to be used at runtime in other
            # action methods
            def register_action_method_from_model(action_model)
                action_name = action_model.name
                validator = LibraryExtension.argument_validator(action_model)
                profile_library.send(:define_method, action_name) do |**arguments|
                    validator.call(arguments)
                    action_model.to_instance_requirements(**arguments)
                end
            end

            # Export the definitions contained in the given profile as actions
            # on this action interface
            #
            # @param [Profile] used_profile the profile that should be used
            # @param [Hash] tag_selection selection for the profile tags, see
            #   {Profile#use_profile}
            # @return [void]
            def use_profile(
                used_profile = nil, tag_selection = {},
                transform_names: ->(name) { name }, &block
            )
                if used_profile && block
                    raise ArgumentError,
                          "must provide either a profile object or a block, but not both"
                elsif block
                    unless tag_selection.empty?
                        raise ArgumentError,
                              "cannot provide a tag selection and a block "\
                              "at the same time"
                    end

                    used_profile = Profile.new(
                        "#{self.name}::<anonymous>", register: false
                    )
                    used_profile.instance_eval(&block)
                elsif !used_profile
                    raise ArgumentError,
                          "must provide either a profile object or a block"
                end

                use_profile_object(
                    used_profile, tag_selection, transform_names: transform_names
                )
            end

            # @api private
            #
            # Internal implementation of {#use_profile} once a Profile object
            # is readily available
            def use_profile_object(
                used_profile = nil, tag_selection = {}, transform_names: ->(name) { name }
            )
                tag_selection = use_profile_tags(used_profile).merge(tag_selection)

                @current_description = nil
                new_definitions = profile.use_profile(
                    used_profile, tag_selection, transform_names: transform_names
                )
                new_definitions.each do |definition|
                    register_action_from_profile(definition.to_action_model)
                end
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            def has_through_method_missing?(name)
                MetaRuby::DSLs.has_through_method_missing?(
                    profile, name, "_tag" => :has_tag?
                ) || super
            end

            def find_through_method_missing(name, args)
                MetaRuby::DSLs.find_through_method_missing(
                    profile, name, args, "_tag" => :find_tag
                ) || super
            end
        end

        # @api private
        #
        # Module injected in Roby::Actions::Models::Interface.
        #
        # The rest of the functionality is directly added to the more generic
        # {Roby::Actions::Models::Library}
        module InterfaceModelExtension
            def setup_main_profile(profile)
                super
                return unless superclass.kind_of?(InterfaceModelExtension)

                tag_map = use_profile_tags(superclass.profile)
                profile.use_profile(superclass.profile, tag_map)
            end
        end

        Roby::Actions::Models::Library.include LibraryExtension
        Roby::Actions::Interface.extend LibraryExtension
        Roby::Actions::Interface.extend InterfaceModelExtension

        # @api private
        #
        # Module injected in {Roby::Actions::Interface}, i.e. instance-level methods
        module InterfaceExtension
            def profile
                self.class.profile
            end

            def has_through_method_missing?(name)
                MetaRuby::DSLs.has_through_method_missing?(
                    profile, m, "_tag" => :has_tag?
                ) || super
            end

            def find_through_method_missing(name, args)
                MetaRuby::DSLs.find_through_method_missing(
                    profile, m, args, "_tag" => :find_tag
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing
        end
        Roby::Actions::Interface.include InterfaceExtension
    end
end
