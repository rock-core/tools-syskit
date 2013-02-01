module Syskit
    module Actions
        # Extension to the models of Roby::Actions::Interface
        module InterfaceModelExtension
            # The main Syskit::Actions::Profile object that is used in an
            # action interface
            attribute(:main_profile) { Syskit::Actions::Profile.new }

            # Export the definitions contained in the given profile as actions
            # on this action interface
            #
            # @param [String,SyskitProfile] the profile that should be used
            # @return [void]
            def use_profile(profile)
                if profile.respond_to?(:to_str)
                    profile_name = profile.to_str
                    profile = find_profile(profile_name)
                    if !profile
                        raise ArgumentError, "no such syskit profile #{profile_name}, known profiles are: #{each_profile.map(&:name)}"
                    end
                end

                main_profile.use_profile(profile)
                profile.definitions.each do |name, req|
                    if !actions[name]
                        actions[name] = ActionModel.new(self, req, "definition from profile #{profile.name}")
                        define_method(name) do
                            main_profile.resolved_definition(name).as_plan
                        end
                    end
                end
            end
        end
        Roby::Actions::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension
    end
end

