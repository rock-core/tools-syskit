module Syskit
    module Actions
        # Extension to the models of Roby::Actions::Interface
        module InterfaceModelExtension
            define_inherited_enumerable(:syskit_profile, :syskit_profiles, :map => true) { Hash.new }
            # Declare a syskit profile on this action interface
            #
            # A syskit profile is a group of dependency injections (use flags)
            # and instance definitions. All the definitions it contains can
            # then be exported on the action interface using
            # {syskit_use_profile}
            #
            # @return [SyskitProfile]
            def syskit_profile(name, &block)
                if const_defined_here?(name)
                    profile = const_get(name)
                else 
                    profile = Profile.new("#{self.name}::#{name}")
                    const_set(name, profile)
                end

                profile.instance_eval(&block)
                syskit_profiles[name] = profile
            end

            # Export the definitions contained in the given profile as actions
            # on this action interface
            #
            # @param [String,SyskitProfile] the profile that should be used
            # @return [void]
            def syskit_use_profile(profile)
                if profile.respond_to?(:to_str)
                    profile_name = profile.to_str
                    profile = find_profile(profile_name)
                    if !profile
                        raise ArgumentError, "no such syskit profile #{profile_name}, known profiles are: #{each_syskit_profile.map(&:name)}"
                    end
                end

                profile.definitions.each do |name, req|
                    actions[name] = ActionModel.new(self, req)
                    define_method(name) do
                        req.as_plan
                    end
                end
            end

            def clear_model
                super if defined? super
                each_syskit_profile do |_, profile|
                    puts "clearing #{profile}"
                    profile.clear_model
                end
                clear_syskit_profiles
            end
        end
        Roby::Actions::Library.include InterfaceModelExtension
        Roby::Actions::Interface.extend InterfaceModelExtension
    end
end

