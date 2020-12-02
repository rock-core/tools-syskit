# frozen_string_literal: true

module Syskit
    module Actions
        # A representation of a set of dependency injections and definition of
        # pre-instanciated models
        class Profile
            include Roby::DRoby::Identifiable

            class << self
                # Set of known profiles
                attr_reader :profiles
            end
            @profiles = []

            dsl_attribute :doc

            # An {InstanceRequirements} object created from a profile {Definition}
            class ProfileInstanceRequirements < InstanceRequirements
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

                def initialize(profile, name, advanced: false)
                    super()
                    self.profile = profile
                    self.advanced = advanced
                    self.name = name
                end

                # Return a definition that has a different underlying profile
                def rebind(profile)
                    if (rebound = profile.find_definition_by_name(name))
                        rebound
                    else
                        result = dup
                        result.profile = profile
                        result
                    end
                end

                def to_action_model(profile = self.profile, doc = self.doc)
                    action_model = super(doc)
                    action_model.name = "#{name}_def"
                    action_model.advanced = advanced?
                    action_model
                end
            end

            class Definition < ProfileInstanceRequirements
                def to_action_model(profile = self.profile, doc = self.doc)
                    resolve.to_action_model(profile, doc || "defined in #{profile}")
                end

                def resolve
                    result = ProfileInstanceRequirements.new(profile, name, advanced: advanced?)
                    result.merge(self)
                    result.name = name
                    profile.inject_di_context(result)
                    result.doc(doc)
                    result
                end
            end

            # Instance-level API for tags
            module Tag
                include Placeholder

                def can_merge?(other)
                    return false unless super

                    other.kind_of?(Tag) &&
                        other.model.tag_name == model.tag_name &&
                        other.model.profile == model.profile
                end
            end

            module Models
                Tag = Syskit::Models::Placeholder
                      .new_specialized_placeholder(task_extension: Profile::Tag) do
                          # The name of this tag
                          attr_accessor :tag_name
                          # The profile this tag has been defined on
                          attr_accessor :profile
                      end
            end

            # Whether this profile should be kept across app setup/cleanup
            # cycles and during model reloading
            attr_predicate :permanent_model?, true

            # Defined here to make profiles look like models w.r.t. Roby's
            # clear_model implementation
            #
            # It does nothing
            def each_submodel; end

            # The call trace at the time of the profile definition
            attr_reader :definition_location
            # The profile name
            # @return [String]
            attr_reader :name
            # The profile's basename
            def basename
                name.gsub(/.*::/, "")
            end

            # The profile's namespace
            def spacename
                name.gsub(/::[^:]*$/, "")
            end
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
            # The deployments available on this profile
            #
            # @return [Models::DeploymentGroup]
            attr_reader :deployment_group
            # A set of deployment groups that can be used to narrow deployments
            # on tasks
            attr_reader :deployment_groups

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

            # Get an argument from a task accessor
            #
            # The common usage for this is to forward an argument from the task's parent:
            #
            #    define 'test', Composition.use(
            #      'some_child' => Model.with_arguments(test: from(:parent_task).test))
            def from(accessor)
                Roby::Task.from(accessor)
            end

            # Get an argument from a state object
            #
            # The common usage for this is to access a state variable
            #
            #    define 'test', Composition.use(
            #      'some_child' => Model.with_arguments(enabled: from_state.enabled?))
            def from_state(state_object = State)
                Roby::Task.from_state(state_object)
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
                @definitions = {}
                @tags = {}
                @used_profiles = []
                @dependency_injection = DependencyInjection.new
                @robot = RobotDefinition.new(self)
                @definition_location = caller_locations
                @deployment_group = Syskit::Models::DeploymentGroup.new
                @deployment_groups = {}
                super()

                if register
                    Profile.profiles << WeakRef.new(self)
                end
            end

            def tag(name, *models)
                tags[name] = Models::Tag.create_for(models, as: "#{self}.#{name}_tag")
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
                unless @di
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
            def promote_requirements(profile, req, tags = {})
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
                tags.transform_keys do |key|
                    if key.respond_to?(:to_str)
                        profile.send("#{key.gsub(/_tag$/, '')}_tag")
                    else key
                    end
                end
            end

            # Whether self uses the given profile
            def uses_profile?(profile)
                used_profiles.any? { |used_profile, _tags| used_profile == profile }
            end

            # Enumerate the profiles that have directly been imported in self
            #
            # @yieldparam [Profile] profile
            def each_used_profile(&block)
                return enum_for(__method__) unless block_given?

                used_profiles.each do |profile, _tags|
                    yield(profile)
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
            def use_profile(profile, tags = {}, transform_names: ->(k) { k })
                invalidate_dependency_injection
                tags = resolve_tag_selection(profile, tags)
                used_profiles.push([profile, tags])
                deployment_group.use_group(profile.deployment_group)

                # Register the definitions, but let the user override
                # definitions of the given profile locally
                new_definitions = []
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
                    rebound_arguments = {}
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
                resolved = resolved_dependency_injection
                           .direct_selection_for(requirements) || requirements
                doc = MetaRuby::DSLs.parse_documentation_block(
                    ->(file) { Roby.app.app_file?(file) }, /^define$/
                )
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
                definitions.key?(name)
            end

            # Enumerate the definitions
            #
            # @yieldparam [Definition] definition
            # @return [void]
            def each_definition
                return enum_for(__method__) unless block_given?

                definitions.each do |name, definition|
                    definition = definition.dup
                    definition.name = name
                    yield(definition)
                end
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
                    req.dup
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
                req = definitions[name]
                unless req
                    raise ArgumentError,
                          "profile #{self.name} has no definition called #{name}"
                end
                req.resolve
            end

            # Enumerate all definitions on this profile and resolve them
            #
            # @yieldparam [Definition] definition the definition resolved with
            #   {#resolved_definition}
            def each_resolved_definition
                return enum_for(__method__) unless block_given?

                definitions.each_value do |req|
                    yield(req.resolve)
                end
            end

            # (see Models::DeploymentGroup#find_deployed_task_by_name)
            def find_deployed_task_by_name(task_name)
                deployment_group.find_deployed_task_by_name(task_name)
            end

            # (see Models::DeploymentGroup#has_deployed_task?)
            def has_deployed_task?(task_name)
                deployment_group.has_deployed_task?(task_name)
            end

            # (see Models::DeploymentGroup#use_group)
            def use_group(group)
                deployment_group.use_group(group)
            end

            # (see Models::DeploymentGroup#use_ruby_tasks)
            def use_ruby_tasks(mappings, on: "ruby_tasks")
                deployment_group.use_ruby_tasks(mappings, on: on)
            end

            # (see Models::DeploymentGroup#use_unmanaged_task)
            def use_unmanaged_task(mappings, on: "unmanaged_tasks")
                deployment_group.use_unmanaged_task(mappings, on: on)
            end

            # (see Models::DeploymentGroup#use_deployment)
            def use_deployment(*names, on: "localhost", loader: nil, **run_options)
                deployment_group.use_deployment(*names, on: on, loader: loader, **run_options)
            end

            # (see Models::DeploymentGroup#use_deployments_from)
            def use_deployments_from(project_name, loader: nil, **use_options)
                deployment_group.use_deployments_from(project_name, loader: loader, **use_options)
            end

            # Create a deployment group to specify definition deployments
            #
            # This only defines the group, but does not declare that the profile
            # should use it. To use a group in a profile, do the following:
            #
            # @example
            #   create_deployment_group 'left_arm' do
            #       use_deployments_from 'left_arm'
            #   end
            #   use_group left_arm_deployment_group
            #
            def define_deployment_group(name, &block)
                group = Syskit::Models::DeploymentGroup.new
                group.instance_eval(&block)
                deployment_groups[name] = group
            end

            # Whether this profile has a group with the given name
            def has_deployment_group?(name)
                deployment_groups.key?(name)
            end

            # Returns a deployment group defined with {#create_deployment_group}
            def find_deployment_group_by_name(name)
                deployment_groups[name]
            end

            # Returns the tag object for a given name
            def find_tag_by_name(name)
                tags[name]
            end

            # Returns all profiles that are used by self
            def all_used_profiles
                resolve_used_profiles([], Set.new)
            end

            # @api private
            #
            # Recursively lists all profiles that are used by self
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
                req.deployment_group.use_group(deployment_group)
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
                @deployment_groups = {}
                @deployment_group = Syskit::Models::DeploymentGroup.new
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
                return enum_for(__method__) unless block_given?

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

            def self.clear_model; end

            # Yield all actions that can be used to access this profile's
            # definitions and devices
            #
            # @yieldparam [Models::Action] action_model
            def each_action
                return enum_for(__method__) unless block_given?

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

            # Whether a tag with this name exists
            def has_tag?(name)
                !!tags[name]
            end

            # Returns a tag by its name
            #
            # @param [String] name
            # @return [Tag,nil]
            def find_tag(name)
                tags[name]
            end

            def has_device?(name)
                !!robot.devices[name]
            end

            # Returns the instance requirements that represent a certain device
            #
            # @param [String] name
            # @return [InstanceRequirements,nil]
            def find_device_requirements_by_name(name)
                if (dev = robot.devices[name])
                    dev.to_instance_requirements.dup
                end
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m,
                    "_tag" => :has_tag?,
                    "_def" => :has_definition?,
                    "_dev" => :has_device?,
                    "_task" => :has_deployed_task?,
                    "_deployment_group" => :has_deployment_group?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    "_tag" => :find_tag,
                    "_def" => :find_definition_by_name,
                    "_dev" => :find_device_requirements_by_name,
                    "_task" => :find_deployed_task_by_name,
                    "_deployment_group" => :find_deployment_group_by_name
                ) || super
            end

            include MetaRuby::DSLs::FindThroughMethodMissing
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
                    profile.doc MetaRuby::DSLs.parse_documentation_block(/.*/, "profile")
                end
                if block
                    profile.instance_eval(&block)
                end
                profile
            end
        end
        Module.include ProfileDefinitionDSL
    end
end
