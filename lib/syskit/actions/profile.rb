module Syskit
    module Actions
        # A representation of a set of dependency injections and definition of
        # pre-instanciated models
        class Profile
            class << self
                # Set of known profiles
                attr_reader :profiles
            end
            @profiles = Array.new

            # The call trace at the time of the profile definition
            attr_reader :definition_location
            # The profile name
            # @return [String]
            attr_reader :name
            # The definitions
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :definitions
            # The set of profiles that have been used in this profile with
            # {use_profile}
            # @return [Array<Profile>]
            attr_reader :used_profiles
            # The DependencyInjection object that is being defined in this
            # profile
            # @return [DependencyInjection]
            attr_reader :dependency_injection
            
            def initialize(name = nil)
                @name = name
                @definitions = Hash.new
                @used_profiles = Array.new
                @dependency_injection = DependencyInjection.new
                @robot = Robot::RobotDefinition.new
                @definition_location = call_stack
                super()
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                dependency_injection.add(*args)
                self
            end

            def to_s
                "Profile(#{name}, uses: #{used_profiles.map(&:name)}, di: #{dependency_injection}, defs: #{definitions.keys.sort.join(",")})"
            end

            # Adds the given profile DI information and registered definitions
            # to this one.
            #
            # If a definitions has the same name in self than in the given
            # profile, the local definition takes precedence
            #
            # @param [Profile] profile
            # @return [void]
            def use_profile(profile)
                used_profiles.push(profile)
                # Register the definitions, but let the user override
                # definitions of the given profile locally
                new_definitions = profile.definitions.map_value { |_, val| val.dup }
                @definitions = new_definitions.merge(definitions)
                robot.use_robot(profile.robot)
                nil
            end

            # Give a name to a known instance requirement object
            #
            # @return [InstanceRequirements] the added instance requirement
            def define(name, requirements)
                definitions[name] = requirements.to_instance_requirements.dup
            end

            # Returns the instance requirement object that represents the given
            # definition in the context of this profile
            #
            # @param [String] name the definition name
            # @return [InstanceRequirements] the instance requirement
            #   representing the definition
            # @raise [ArgumentError] if the definition does not exist
            # @see resolved_definition
            def definition(name)
                req = definitions[name]
                if !req
                    raise ArgumentError, "#{self} has no definition called #{name}"
                end
                req
            end

            # Returns the instance requirement object that represents the given
            # definition, with all the dependency injection information
            # contained in this profile applied
            #
            # @param [String] name the definition name
            # @return [InstanceRequirements] the instance requirement
            #   representing the definition
            # @raise [ArgumentError] if the definition does not exist
            # @see definition
            def resolved_definition(name)
                req = definition(name).dup
                inject_di_context(req)
                req
            end

            # Injects the DI information registered in this profile in the given
            # instance requirements
            #
            # @param [InstanceRequirements] the instance requirement object
            # @return [void]
            def inject_di_context(req)
                req.dependency_injection_context.push(robot.to_dependency_injection)
                used_profiles.each do |prof|
                    prof.inject_di_context(req)
                end
                req.dependency_injection_context.push(dependency_injection)
                super if defined? super
                nil
            end

            def initialize_copy(old)
                super
                old.definitions.each do |name, req|
                    definitions[name] = req.dup
                end
            end

            # @overload robot
            # @overload robot { ... }
            #
            # Gets and/or modifies the robot definition of this profile
            #
            # @return [Syskit::Robot::RobotDefinition] the robot definition
            #   object
            def robot(&block)
                if block_given?
                    @robot.instance_eval(&block)
                end
                @robot
            end

            # Clears this profile of all data, leaving it blank
            #
            # This is mostly used in Roby's model-reloading procedures
            def clear_model
                @robot = Robot::RobotDefinition.new
                definitions.clear
                @dependency_injection = DependencyInjection.new
                used_profiles.clear
                super if defined? super
            end

            # Clear all registered profiles
            def self.clear_model
                profiles.each do |prof|
                    prof.clear_model
                end
                profiles.clear
            end

            def method_missing(m, *args)
                if m.to_s =~ /^(\w+)_def$/
                    defname = $1
                    if !definitions[defname]
                        raise NoMethodError, "#{name} has no definition called #{defname}"
                    elsif !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    return definition(defname)
                elsif m.to_s =~ /^(\w+)_dev$/
                    devname = $1
                    if !robot.devices[devname]
                        raise NoMethodError, "#{name} has no device called #{devname}"
                    elsif !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    return robot.devices[devname]
                end
                super
            end
        end

        module ProfileDefinitionDSL
            # Declares a new syskit profile, and registers it as a constant on
            # this module
            #
            # A syskit profile is a group of dependency injections (use flags)
            # and instance definitions. All the definitions it contains can
            # then be exported on an action interface using
            # {use_profile}
            #
            # @return [Syskit::Actions::Profile]
            def profile(name, &block)
                if const_defined_here?(name)
                    profile = const_get(name)
                else 
                    profile = Profile.new("#{self.name}::#{name}")
                    const_set(name, profile)
                end
                Profile.profiles << profile
                profile.instance_eval(&block)
            end
        end
        Module.include ProfileDefinitionDSL
    end
end


