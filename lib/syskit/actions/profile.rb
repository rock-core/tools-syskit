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

            class Definition < InstanceRequirements
                attr_accessor :profile
                def initialize(profile, name)
                    super()
                    self.profile = profile
                    self.name = name
                end

                def initialize_copy(new)
                    super
                    new.profile = profile
                    new.name = name
                end

                def to_action_model
                    profile.resolved_definition(name).to_action_model(profile, "defined in #{profile}")
                end
            end

            module Tag
                include Syskit::PlaceholderTask

                module ClassExtension
                    # The name of this tag
                    attr_accessor :tag_name
                    # The profile this tag has been defined on
                    attr_accessor :profile
                end
            end

            # The call trace at the time of the profile definition
            attr_reader :definition_location
            # The profile name
            # @return [String]
            attr_reader :name
            # The definitions
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :definitions
            # The tags
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :tags
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
                @tags = Hash.new
                @used_profiles = Array.new
                @dependency_injection = DependencyInjection.new
                @robot = Robot::RobotDefinition.new
                @definition_location = call_stack
                super()
            end

            def tag(name, *models)
                tags[name] = Syskit.create_proxy_task_model_for(models,
                                                                :extension => Tag,
                                                                :as => "#{self}.#{name}_tag")
                tags[name].tag_name = name
                tags[name].profile = self
                tags[name]
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                @di = nil
                dependency_injection.add(*args)
                self
            end

            def resolved_dependency_injection
                if !@di
                    di = DependencyInjectionContext.new
                    di.push(robot.to_dependency_injection)
                    all_used_profiles.each do |prof, _|
                        di.push(prof.dependency_injection)
                    end
                    di.push(dependency_injection)
                    @di = di.current_state
                end
                @di
            end

            def to_s
                name
            end

            # Promote requirements taken from another profile to this profile
            #
            # @param [Profile] profile the profile the requirements are
            #   originating from
            # @param [InstanceRequirements] req the instance requirement object
            # @param [{String=>Object}] tags selections for tags in profile,
            #   from the tag name to the selected object
            # @return [InstanceRequirements] the promoted requirement object. It
            #   might be the same than the req parameter (i.e. it is not
            #   guaranteed to be a copy)
            def promote_requirements(profile, req, tags = Hash.new)
                if req.composition_model?
                    tags = resolve_tag_selection(profile, tags)
                    req = req.dup
                    req.push_selections
                    req.use(tags)
                end
                req
            end

            # Resolves the names in the tags argument given to {#use_profile}
            def resolve_tag_selection(profile, tags)
                tags.map_key do |key, _|
                    if key.respond_to?(:to_str)
                        profile.send("#{key.gsub(/_tag$/, '')}_tag")
                    else key
                    end
                end
            end

            # Adds the given profile DI information and registered definitions
            # to this one.
            #
            # If a definitions has the same name in self than in the given
            # profile, the local definition takes precedence
            #
            # @param [Profile] profile
            # @return [void]
            def use_profile(profile, tags = Hash.new)
                @di = nil
                tags = resolve_tag_selection(profile, tags)
                used_profiles.push([profile, tags])

                # Register the definitions, but let the user override
                # definitions of the given profile locally
                profile.definitions.each do |name, req|
                    if !definitions[name]
                        req = promote_requirements(profile, req, tags)
                        define name, req
                    end
                end
                robot.use_robot(profile.robot)
                super if defined? super
                nil
            end

            # Give a name to a known instance requirement object
            #
            # @return [InstanceRequirements] the added instance requirement
            def define(name, requirements)
                resolved = resolved_dependency_injection.
                    direct_selection_for(requirements) || requirements
                req = resolved.to_instance_requirements
                
                definition = Definition.new(self, name)
                definition.merge(req)
                definitions[name] = definition
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
                    raise ArgumentError, "profile #{self.name} has no definition called #{name}"
                end
                req = req.dup
                req.name = name
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
                req = definition(name)

                result = InstanceRequirements.new
                result.merge(req)
                inject_di_context(result)
                result
            end

            def all_used_profiles
                resolve_used_profiles(Array.new, Set.new)
            end

            def resolve_used_profiles(list, set)
                new_profiles = used_profiles.find_all do |p, _|
                    !set.include?(p)
                end
                list.concat(new_profiles)
                set |= new_profiles.map(&:first).to_set
                new_profiles.each do |p, _|
                    p.resolve_used_profiles(list, set)
                end
                list
            end

            # Injects the DI information registered in this profile in the given
            # instance requirements
            #
            # @param [InstanceRequirements] req the instance requirement object
            # @return [void]
            def inject_di_context(req)
                req.push_dependency_injection(resolved_dependency_injection)
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

            def each_action
                return enum_for(__method__) if !block_given?

                robot.devices.each_value do |dev|
                    req = dev.to_instance_requirements
                    inject_di_context(req)
                    action_model = Models::Action.new(self, req, "device from profile #{name}")
                    action_model.name = "#{dev.name}_dev"
                    yield(action_model)
                end

                definitions.each do |name, req|
                    action_name = "#{name}_def"

                    req = resolved_definition(name)
                    action_model = req.to_action_model(self, "defined in profile #{self}")
                    action_model.name = action_name
                    yield(action_model)
                end
            end

            def method_missing(m, *args)
                if m.to_s =~ /^(\w+)_tag$/
                    tag_name = $1
                    if !tags[tag_name]
                        raise NoMethodError.new(m), "#{name} has no tag called #{tag_name}"
                    elsif !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    return tags[tag_name]
                elsif m.to_s =~ /^(\w+)_def$/
                    defname = $1
                    if !definitions[defname]
                        raise NoMethodError.new(m), "#{name} has no definition called #{defname}"
                    elsif !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    return definition(defname)
                elsif m.to_s =~ /^(\w+)_dev$/
                    devname = $1
                    if !robot.devices[devname]
                        raise NoMethodError.new(m), "#{name} has no device called #{devname}"
                    elsif !args.empty?
                        raise ArgumentError, "expected zero arguments, got #{args.size}"
                    end
                    return robot.devices[devname]
                end
                super
            end

            include Roby::Distributed::DRobyConstant::Dump
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


