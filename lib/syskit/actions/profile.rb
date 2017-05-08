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

            # A definition object created with {#define}
            #
            # In addition to the {InstanceRequirements} duties, it also adds
            # information about the link of the requirements with its profile
            class Definition < InstanceRequirements
                # The profile this definition comes from
                #
                # @return [Profile]
                attr_accessor :profile

                # @method! advanced?
                # @method! advanced=(flag)
                #
                # Whether this is an advanced definition. This is purely a hint
                # for UIs
                attr_predicate :advanced?, true

                # @!method resolved?
                # @!method resolved=(flag)
                #
                # Whether this definition has been injected with its profile's
                # DI information
                attr_predicate :resolved?

                def initialize(profile, name, resolved: false)
                    super()
                    self.profile = profile
                    self.advanced = false
                    self.name = name
                    @resolved = resolved
                end

                # Return a definition that has a different underlying profile
                def rebind(profile)
                    if rebound = profile.find_definition_by_name(name)
                        rebound.dup
                    else
                        result = dup
                        result.profile = profile
                        result
                    end
                end

                # Create an action model that encapsulate this definition
                def to_action_model
                    if resolved?
                        action_model = super(doc || "defined in #{profile}")
                        action_model.advanced = advanced?
                        action_model.name = "#{name}_def"
                        action_model
                    else
                        profile.resolved_definition(name).to_action_model
                    end
                end
            end

            module Models
                # Model-level API for {Profile::Tag}
                module Tag
                    # The name of this tag
                    # @return [String]
                    attr_accessor :tag_name
                    # The profile this tag has been defined on
                    # @return [Profile]
                    attr_accessor :profile
                end
            end

            module Tag
                include Syskit::PlaceholderTask

                def can_merge?(other)
                    return false if !super

                    other.kind_of?(Tag) &&
                        other.model.tag_name == model.tag_name &&
                        other.model.profile == model.profile
                end

                module ClassExtension
                    include Models::Tag
                end
            end

            # Whether this profile should be kept across app setup/cleanup
            # cycles and during model reloading
            attr_predicate :permanent_model?, true

            # Defined here to make profiles look like models w.r.t. Roby's
            # clear_model implementation
            #
            # It does nothing
            def each_submodel
            end

            # The call trace at the time of the profile definition
            attr_reader :definition_location
            # The profile name
            # @return [String]
            attr_reader :name
            # The profile's basename
            def basename; name.gsub(/.*::/, '') end
            # The profile's namespace
            def spacename; name.gsub(/::[^:]*$/, '') end
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

            # Dependency injection object that signifies "select nothing for
            # this"
            #
            # This is used to override more generic selections, or to make sure
            # that a compositions' optional child is not present
            #
            # @example disable the optional 'pose' child of Camera composition
            #   Compositions::Camera.use('pose' => nothing)
            #
            def nothing
                DependencyInjection.nothing
            end

            # Robot definition class inside a profile
            #
            # It is subclassed so that we can invalidate the cached dependency
            # injection object whenever the robot gets modified
            class RobotDefinition < Syskit::Robot::RobotDefinition
                # @return [Profile] the profile object this robot definition is
                #   part of
                attr_reader :profile

                def initialize(profile)
                    @profile = profile
                    super()
                end

                def invalidate_dependency_injection
                    super
                    profile.invalidate_dependency_injection
                end

                def to_s
                    "#{profile.name}.robot"
                end
            end
            
            def initialize(name = nil, register: false)
                @name = name
                @permanent_model = false
                @definitions = Hash.new
                @tags = Hash.new
                @used_profiles = Array.new
                @dependency_injection = DependencyInjection.new
                @robot = RobotDefinition.new(self)
                @definition_location = caller_locations
                super()

                if register
                    Profile.profiles << WeakRef.new(self)
                end
            end

            def tag(name, *models)
                tags[name] = Syskit.create_proxy_task_model_for(models,
                                                                :extension => Tag,
                                                                :as => "#{self}.#{name}_tag")
                tags[name].tag_name = name
                tags[name].profile = self
                tags[name]
            end

            # Enumerate the tags declared on this profile
            #
            # It never enumerates tags from used profiles
            #
            # @yieldparam [Models::Tag]
            def each_tag(&block)
                tags.each_value(&block)
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                invalidate_dependency_injection
                dependency_injection.add(*args)
                self
            end

            # Invalidate the cached dependency inject object
            #
            # @see resolved_dependency_injection
            def invalidate_dependency_injection
                @di = nil
            end

            # @api private
            #
            # Resolve the profile's global dependency injection object
            #
            # This is an internal cache, and is updated as-needed
            #
            # @see invalidate_dependency_injection
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
                "profile:#{name}"
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
                    req = req.dup
                    tags = resolve_tag_selection(profile, tags)
                    req.push_selections
                    req.use(tags)
                end
                req
            end

            # @api private
            #
            # Resolves the names in the tags argument given to {#use_profile}
            def resolve_tag_selection(profile, tags)
                tags.map_key do |key, _|
                    if key.respond_to?(:to_str)
                        profile.send("#{key.gsub(/_tag$/, '')}_tag")
                    else key
                    end
                end
            end

            # Whether self uses the given profile
            def uses_profile?(profile)
                used_profiles.any? { |used_profile, _| used_profile == profile }
            end

            # Adds the given profile DI information and registered definitions
            # to this one.
            #
            # If a definitions has the same name in self than in the given
            # profile, the local definition takes precedence
            #
            # @param [Profile] profile
            # @return [void]
            def use_profile(profile, tags = Hash.new, transform_names: ->(k) { k })
                invalidate_dependency_injection
                tags = resolve_tag_selection(profile, tags)
                used_profiles.push([profile, tags])

                # Register the definitions, but let the user override
                # definitions of the given profile locally
                new_definitions = Array.new
                profile.definitions.each do |name, req|
                    name = transform_names.call(name)
                    req = promote_requirements(profile, req, tags)
                    definition = register_definition(name, req, doc: req.doc)
                    new_definitions << definition
                end
                new_definitions.concat(robot.use_robot(profile.robot))

                # Now, map possible IR objects or IR-derived Action objects that
                # are present within the arguments
                new_definitions.each do |req|
                    rebound_arguments = Hash.new
                    req.arguments.each do |name, value|
                        if value.respond_to?(:rebind_requirements)
                            rebound_arguments[name] = value.rebind_requirements(self)
                        end
                    end
                    req.with_arguments(**rebound_arguments)
                end

                super if defined? super
                new_definitions
            end

            # Create a new definition based on a given instance requirement
            # object
            #
            # @param [String] the definition name
            # @param [#to_instance_requirements] requirements the IR object
            # @return [Definition] the added instance requirement
            def define(name, requirements)
                resolved = resolved_dependency_injection.
                    direct_selection_for(requirements) || requirements
                doc = MetaRuby::DSLs.parse_documentation_block(
                    ->(file) { Roby.app.app_file?(file) }, /^define$/)
                register_definition(name, resolved.to_instance_requirements, doc: doc)
            end

            # @api private
            #
            # Register requirements to a definition name
            #
            # @return [Definition] the definition object
            def register_definition(name, requirements, doc: nil)
                definition = Definition.new(self, name)
                definition.doc(doc) if doc
                definition.advanced = false
                definition.merge(requirements)
                definitions[name] = definition
            end

            # Test if this profile has a definition with the given name
            def has_definition?(name)
                definitions.has_key?(name)
            end

            # Returns the instance requirement object that represents the given
            # definition
            #
            # @param (see #find_definition_by_name)
            # @raise [ArgumentError] if the definition does not exist
            # @see resolved_definition
            def definition(name)
                if req = find_definition_by_name(name)
                    req
                else
                    raise ArgumentError, "profile #{self.name} has no definition called #{name}"
                end
            end

            # Returns the instance requirement object that represents the given
            # definition, if there is one
            #
            # @param [String] name the definition name
            # @return [nil,InstanceRequirements] the object matching the given
            #   name, or nil if there is none
            # @see definition resolved_definition
            def find_definition_by_name(name)
                if req = definitions[name]
                    req = req.dup
                    req.name = name
                    req
                end
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

                result = Definition.new(self, name, resolved: true)
                result.merge(req)
                inject_di_context(result)
                result.name = req.name
                result.doc(req.doc)
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

                if MetaRuby::Registration.accessible_by_name?(self)
                    MetaRuby::Registration.deregister_constant(self)
                end

                Profile.deregister_profile(self)
            end

            # Helper method that allows to iterate over the registered profiles
            # and possibly delete some of them
            #
            # @yieldparam [Profile] profile
            # @yieldreturn [Boolean] true if this profile should be deleted,
            #   false otherwise
            def self.filter_submodels
                profiles.delete_if do |weakref|
                    begin
                        obj = weakref.__getobj__
                        yield(obj)
                    rescue WeakRef::RefError
                        true
                    end
                end
            end

            # Defined here to make profiles look like models w.r.t. Roby's
            # clear_model implementation
            #
            # It enumerates the profiles created so far
            def self.each_submodel
                return enum_for(__method__) if !block_given?
                filter_submodels do |profile|
                    yield(profile)
                    false
                end
            end

            def self.register_profile(profile)
                profiles << WeakRef.new(profile)
            end

            def self.deregister_profile(profile)
                filter_submodels do |pr|
                    pr == profile
                end
            end

            def self.clear_model
            end

            # Yield all actions that can be used to access this profile's
            # definitions and devices
            #
            # @yieldparam [Models::Action] action_model
            def each_action
                return enum_for(__method__) if !block_given?

                robot.each_master_device do |dev|
                    action_model = dev.to_action_model
                    yield(action_model)
                end

                definitions.each do |name, req|
                    action_model = req.to_action_model
                    action_model.name = "#{name}_def"
                    yield(action_model)
                end
            end

            # Returns a tag by its name
            #
            # @param [String] name
            # @return [Tag,nil]
            def find_tag(name)
                tags[name]
            end

            # Returns the instance requirements that represent a certain device
            #
            # @param [String] name
            # @return [InstanceRequirements,nil]
            def find_device_requirements_by_name(name)
                if dev = robot.devices[name]
                    dev.to_instance_requirements.dup
                end
            end

            def find_through_method_missing(m, args, call: true)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    'tag' => :find_tag,
                    'def' => :find_definition_by_name,
                    'dev' => :find_device_requirements_by_name, call: call)
            end

            def respond_to_missing?(m, include_private)
                !!find_through_method_missing(m, [], call: false) || super
            end

            def method_missing(m, *args)
                find_through_method_missing(m, args) || super
            end

            include Roby::DRoby::V5::DRobyConstant::Dump
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
                    profile = Profile.new("#{self.name}::#{name}", register: true)
                    const_set(name, profile)
                end
                profile.instance_eval(&block)
                profile
            end
        end
        Module.include ProfileDefinitionDSL
    end
end


