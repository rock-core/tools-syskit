module Syskit
        # Representation and manipulation of dependency injection selection
        class DependencyInjection
            attr_reader :explicit
            attr_reader :defaults

            def hash; [explicit, defaults].hash end
            def eql?(obj)
                obj.kind_of?(DependencyInjection) &&
                    explicit == obj.explicit &&
                    defaults == obj.defaults
            end
            def ==(obj); eql?(obj) end

            # creates a new DependencyInjection instance
            #
            # If arguments are provided, they must match the format expected by
            # #add
            def initialize(*base)
                @explicit = Hash.new
                @defaults = Set.new
                if !base.empty?
                    add(*base)
                end
            end

            # True if this object contains no selection at all
            def empty?
                @explicit.empty? && @defaults.empty?
            end

            def clear
                explicit.clear
                defaults.clear
            end

            def to_s # :nodoc:
                explicit = self.explicit.map { |k, v| [k.to_s, v.to_s] }.sort_by(&:first).map { |k, v| "#{k} => #{v}" }
                defaults = self.defaults.map(&:to_s)
                "#<DependencyInjection: #{defaults.concat(explicit).join(", ")}>"
            end

            def pretty_print(pp)
                pp.text "DependencyInjection"

                pp.breakable
                pp.text "Explicit:"
                if !explicit.empty?
                    pp.nest(2) do
                        pp.breakable
                        explicit = self.explicit.map do |k, v|
                            k = k.short_name
                            v = v.short_name
                            [k, "#{k} => #{v}"]
                        end.sort_by(&:first)
                        pp.seplist(explicit) do |kv|
                            pp.text kv[1]
                        end
                    end
                end

                pp.breakable
                pp.text "Defaults:"
                if !defaults.empty?
                    pp.nest(2) do
                        pp.breakable
                        defaults = self.defaults.map(&:to_s).sort
                        pp.seplist(defaults) do |v|
                            pp.text v.to_s
                        end
                    end
                end
            end

            # call-seq:
            #   add(default0, default1, key0 => value0)
            #   add([default0, default1], key0 => value0)
            #   add(dependency_injection)
            #
            # Add default and explicit selections in one call
            def add(*mappings)
                if mappings.size == 1 && mappings.first.kind_of?(DependencyInjection)
                    deps = mappings.first
                    explicit, defaults = deps.explicit, deps.defaults
                else
                    explicit, defaults = DependencyInjection.validate_use_argument(*mappings)
                end

                add_explicit(explicit)
                add_defaults(defaults)
                self
            end

            # Add a new dependency injection pattern to the current set
            #
            # The new mapping overrides existing mappings
            def add_explicit(mappings)
                # Invalidate the @resolved cached
                @resolved = nil
                explicit.merge!(mappings)
                @explicit = DependencyInjection.resolve_recursive_selection_mapping(explicit)
            end

            # Add a list of objects to the default list. 
            def add_defaults(list)
                # Invalidate the @resolved cached
                @resolved = nil
                @defaults |= list
                seen = Set.new
                @defaults.delete_if do |obj|
                    if seen.include?(obj)
                        true
                    else
                        seen << obj
                        false
                    end
                end
            end

            # Returns true if this object contains a selection for the given
            # criteria
            #
            # See #candidates_for for the description of the criteria list
            def has_selection?(*criteria)
                !candidates_for(*criteria).empty?
            end

            # Returns a list of candidates for the given selection criteria
            # based on the information in +self+
            def candidates_for(*criteria)
                if defaults.empty?
                    selection = self.explicit
                else
                    @resolved ||= resolve
                    return @resolved.candidates_for(*criteria)
                end

                criteria.each do |obj|
                    required_models = []
                    case obj
                    when String
                        if result = selection[obj]
                            return [result]
                        end
                    when InstanceRequirements
                        required_models = obj.models
                    when Models::DataServiceModel
                        required_models = [obj]
                    else
                        if obj <= Component
                            required_models = [obj]
                        else
                            raise ArgumentError, "unknown criteria object #{obj}, expected a string or an InstanceRequirements object"
                        end
                    end

                    candidates = required_models.inject(Set.new) do |candidates, m|
                        candidates << (selection[m] || selection[m.name])
                    end
                    candidates.delete(nil)
                    if !candidates.empty?
                        return candidates
                    end
                end
                []
            end

            # Like #candidates_for, but returns a single match
            #
            # The match is either nil if there is an ambiguity (multiple
            # matches) or if there is no match.
            def selection_for(*criteria)
                candidates = candidates_for(*criteria)
                if candidates.size == 1
                    return candidates.first
                end
            end

            def initialize_copy(from)
                @resolved = nil
                @explicit = from.explicit.map_value do |key, obj|
                    case obj
                    when InstanceRequirements, InstanceSelection
                        obj.dup
                    else obj
                    end
                end
                @defaults = Set.new
                from.defaults.each do |obj|
                    obj =
                        case obj
                        when InstanceRequirements, InstanceSelection
                            obj.dup
                        else obj
                        end

                    @defaults << obj
                end
            end

            # Resolves the selections by generating a direct mapping (as a hash)
            # representing the required selection
            def resolve
                result = DependencyInjection.resolve_default_selections(explicit, self.defaults)
                DependencyInjection.new(DependencyInjection.resolve_recursive_selection_mapping(result))
            end

            def resolve_name(name, mappings)
                if name =~ /(.*)\.(\w+)$/
                    object_name, service_name = $1, $2
                else
                    object_name = name
                end

                main_object = DependencyInjection.resolve_selection_recursively(object_name, mappings)
                if main_object.respond_to?(:to_str)
                    raise NameResolutionError.new(object_name), "#{object_name} is not a known device or definition"
                end

                if service_name
                    main_object = InstanceSelection.from_object(main_object, InstanceRequirements.new, false)
                    if !(task_model = main_object.requirements.models.find { |m| m <= Roby::Task })
                        raise ArgumentError, "while resolving #{name}: cannot explicitely select a service on something that is not a task"
                    end

                    if service = InstanceSelection.select_service_by_name(task_model, service_name)
                        service
                    else
                        raise ArgumentError, "cannot find service #{service_name} on #{object_name}"
                    end
                end

                main_object
            end

            # Recursively resolve the selections that are specified as strings
            # using the provided block
            def resolve_names(mapping = self.explicit, &block)
                map! do |v|
                    if v.respond_to?(:to_str)
                        resolve_name(v, mapping)
                    elsif v.respond_to?(:resolve_names)
                        v.resolve_names(&block)
                        v
                    else v
                    end
                end
            end

            # Removes the unresolved instances from the list of selections
            #
            # So far, unresolved selections are the ones that are represented as
            # strings. The entries are not removed per se, but they are replaced
            # by nil, to mark "do not use" selections.
            def remove_unresolved
                defaults.delete_if { |v| v.respond_to?(:to_str) }
                map! do |value|
                    if value.respond_to?(:to_str)
                        nil
                    else value
                    end
                end
            end

            # Create a new DependencyInjection object, with a modified selection
            #
            # Like #map!, this method yields the [selection_key,
            # selected_instance] pairs to a block that must return a new value
            # for the for +selected_instance+.
            def map(&block)
                copy = dup
                copy.map!(&block)
            end

            # Changes the selections
            #
            # This method yields the [selection_key, selected_instance] pairs to
            # a block that must return a new value for the for
            # +selected_instance+. It modifies +self+
            def map!(&block)
                # Invalidate the @resolved cached
                @resolved = nil
                changed = false
                explicit = self.explicit.map_value do |k, v|
                    result = yield(v)
                    changed ||= (result != v)
                    result
                end
                if changed
                    @explicit = DependencyInjection.resolve_recursive_selection_mapping(explicit)
                end

                @defaults.map! do |v|
                    yield(v)
                end
                self
            end

            def each_selection_key(&block)
                explicit.each_key(&block)
            end

            # Merge the selections in +other+ into +self+.
            #
            # If both objects provide selections for the same keys,
            # raises ArgumentError if the two selections are incompatible
            def merge(other)
                # Invalidate the @resolved cached
                @resolved = nil
                @explicit.merge!(other.explicit) do |match, model1, model2|
                    if model1 <= model2
                        model1
                    elsif model2 <= model1
                        model2
                    else
                        raise ArgumentError, "cannot use both #{model1} and #{model2} for #{match}"
                    end
                end
                @defaults |= other.defaults
            end

            # Helper method that resolves recursive selections in a dependency
            # injection mapping
            def self.resolve_recursive_selection_mapping(spec)
                spec.map_value do |key, value|
                    while (new_value = spec[value])
                        value = new_value
                    end
                    value
                end
            end

            # Helper method that resolves one single object recursively
            def self.resolve_selection_recursively(value, spec)
                while (new_value = spec[value])
                    value = new_value
                end
                value
            end

            # Helper methods that adds to a dependency inject mapping a list of
            # default selections
            #
            # Default selections are a list of objects for which no
            # specification is used. They are resolved as "select X for all
            # models of X for which there is no explicit selection already"
            def self.resolve_default_selections(using_spec, default_selections)
                if !default_selections || default_selections.empty?
                    return using_spec
                end

                Engine.debug do
                    Engine.debug "Resolving default selections"
                    default_selections.map(&:to_s).sort.each do |sel|
                        Engine.debug "    #{sel}"
                    end
                    Engine.debug "  into"
                    using_spec.map { |k, v| [k.to_s, v.to_s] }.sort.each do |k, v|
                        Engine.debug "    #{k} => #{v}"
                    end
                    Engine.debug "  rejections:"
                    break
                end

                result = using_spec.dup

                ambiguous_default_selections = Hash.new
                resolved_default_selections = Hash.new

                default_selections.each do |selection|
                    selection = resolve_selection_recursively(selection, using_spec)
                    selection.each_fullfilled_model do |m|
                        if using_spec[m]
                            Engine.debug do
                                Engine.debug "  rejected #{selection.short_name}"
                                Engine.debug "    for #{m.short_name}"
                                Engine.debug "    reason: already explicitely selected"
                                break
                            end
                        elsif ambiguous_default_selections.has_key?(m)
                            ambiguity = ambiguous_default_selections[m]
                            Engine.debug do
                                Engine.debug "  rejected #{selection.short_name}"
                                Engine.debug "    for #{m.short_name}"
                                Engine.debug "    reason: ambiguity with"
                                ambiguity.each do |model|
                                    Engine.debug "      #{model.short_name}"
                                end
                                break
                            end
                            ambiguity << selection
                        elsif resolved_default_selections[m] && resolved_default_selections[m] != selection
                            removed = resolved_default_selections.delete(m)
                            ambiguous_default_selections[m] = [selection, removed].to_set
                            Engine.debug do
                                Engine.debug "  removing #{removed.short_name}"
                                Engine.debug "    for #{m.short_name}"
                                Engine.debug "    reason: ambiguity with"
                                Engine.debug "      #{selection.short_name}"
                                break
                            end
                        elsif selection != m
                            Engine.debug do
                                Engine.debug "  adding #{selection.short_name}"
                                Engine.debug "    for #{m.short_name}"
                                break
                            end
                            resolved_default_selections[m] = selection
                        end
                    end
                end
                Engine.debug do
                    Engine.debug "  selected defaults:"
                    resolved_default_selections.each do |key, sel|
                        Engine.debug "    #{key.respond_to?(:short_name) ? key.short_name : key}: #{sel}"
                    end
                    break
                end
                result.merge!(resolved_default_selections)
            end

            # Helper method that separates the default selections from the
            # explicit selections in the call to #use
            #
            # @return <Hash, Array> the explicit selections and a list of
            #     default selections
            def self.validate_use_argument(*mappings)
                explicit = Hash.new
                defaults = Array.new
                mappings.each do |element|
                    if element.kind_of?(Hash)
                        explicit.merge!(element)
                    else
                        defaults << element
                    end
                end
                return explicit, defaults
            end
        end

        # Representation of a selection context, as a stack of
        # DependencyInjection objects
        #
        # This represents a prioritized set of selections (as
        # DependencyInjection objects). It is mainly used during instanciation
        # to find _what_ should be instanciated.
        #
        # In the stack, the latest selection added with #push takes priority
        # over everything that has been added before it. During resolution, if
        # nothing is found at a certain level, then the previous levels will be
        # queried.
        #
        # Use #selection_for and #candidates_for to query the selection. Use
        # #save, #restore and #push to manage the stack
        class DependencyInjectionContext
            StackLevel = Struct.new :resolver, :added_info

            # The stack of StackLevel objects added with #push
            attr_reader :stack
            # The resolved selections. When a query is made at a certain level
            # of the stack, it gets resolved into one single explicit selection
            # hash, to optimize repeated queries.
            attr_reader :state
            # The list of savepoints
            #
            # They are stored as sizes of +stack+. I.e. #restore simply resizes
            # +stack+ and +state+ to the size stored in +save.last+
            attr_reader :savepoints

            # Creates a new dependency injection context
            #
            # +base+ is the root selection context (can be nil). It can either
            # be a hash or a DependencyInjection object. In the first case, it
            # is interpreted as a selection hash usable in
            # DependencyInjection#use, and is converted to the corresponding
            # DependencyInjection object this way.
            def initialize(base = nil)
                @stack = []
                @state = []
                @savepoints = []

                # Add a guard on the stack, so that #push does not have to care
                stack << StackLevel.new(DependencyInjection.new, Hash.new)

                case base
                when Hash
                    deps = DependencyInjection.new(base)
                    push(deps)
                when DependencyInjection
                    push(base)
                when NilClass
                else
                    raise ArgumentError, "expected either a selection hash or a DependencyInjection object as base selection, got #{base}"
                end
            end

            def pretty_print(pp)
                current_state.pretty_print(pp)
            end

            def initialize_copy(obj)
                @stack = obj.stack.dup
                @state = obj.state.dup
                @savepoints  = obj.savepoints.dup
            end


            # Pushes the current state of the context. #restore will go back to
            # this exact state, regardless of the number of #push calls.
            #
            # The save/restore mechanism is stack-based, so when doing
            #
            #   save
            #   save
            #   restore
            #   restore
            #
            # The first restore returns to the state in the second save and the
            # second restore returns to the state in thef first save.
            def save
                if !block_given?
                    @savepoints << stack.size
                else
                    save
                    begin
                        yield
                    ensure
                        restore
                    end
                end
            end

            # Returns the resolved state of the selection stack, as a
            # DependencyInjection object.
            #
            # Calling #candidates_for and #selection_for on the resolved object
            # is equivalent to resolving the complete stack
            def current_state
                stack.last.resolver
            end

            # The opposite of #save
            def restore
                expected_size = @savepoints.pop
                if !expected_size
                    raise ArgumentError, "save/restore stack is empty"
                end

                @stack = stack[0, expected_size]
                if state.size > expected_size
                    @state = state[0, expected_size]
                end
            end

            # Returns all the candidates that match +criteria+ in the current
            # state of this context
            #
            # See DependencyInjection#candidates_for for the format of
            # +criteria+
            def candidates_for(*criteria)
                current_state.candidates_for(*criteria)
            end

            # Returns a non-ambiguous selection for the given criteria
            #
            # Returns nil if no selection is defined, or if there is an
            # ambiguity (i.e. multiple candidates exist)
            #
            # See DependencyInjection#candidates_for for the format of
            # +criteria+
            #
            # See also #candidates_for
            def selection_for(*criteria)
                current_state.selection_for(*criteria)
            end

            # Adds a new dependency injection context on the stack
            def push(spec)
                if spec.empty?
                    stack << StackLevel.new(stack.last.resolver, DependencyInjection.new)
                    return
                end

                spec = DependencyInjection.new(spec)

                new_state = stack.last.resolver.dup
                # Resolve all names
                spec.resolve_names(new_state.explicit.merge(spec.explicit))
                # Resolve recursive selection, and default selections
                spec = spec.resolve
                # Finally, add it to the new state
                new_state.add(spec)
                # ... and to the stack
                stack << StackLevel.new(new_state, spec)
            end

            # Returns the StackLevel object representing the last added level on
            # the stack
            def top
                stack.last
            end

            # Removes the last dependency injection context stored on the stack,
            # and returns it.
            #
            # Will stop at the last saved context (saved with #save). Returns
            # nil in this case
            def pop
                if stack.size == 1
                    return
                end

                expected_size = @savepoints.last
                if expected_size && expected_size == stack.size
                    return
                end

                result = stack.pop
                if state.size > stack.size
                    @state = state[0, stack.size]
                end
                result
            end
        end
end

