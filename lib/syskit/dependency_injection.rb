module Syskit
        # Representation and manipulation of dependency injection selection
        class DependencyInjection
            extend Logger::Hierarchy
            extend Logger::Forward

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

            def initialize_copy(from)
                @resolved = nil
                @explicit = from.explicit.map_value do |key, obj|
                    case obj
                    when InstanceRequirements
                        obj.dup
                    else obj
                    end
                end
                @defaults = Set.new
                from.defaults.each do |obj|
                    obj =
                        case obj
                        when InstanceRequirements
                            obj.dup
                        else obj
                        end

                    @defaults << obj
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
                "#{defaults.concat(explicit).join(", ")}"
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

            # @overload add(default0, default1, key0 => value0)
            # @overload add([default0, default1], key0 => value0)
            # @overload add(dependency_injection)
            #
            # Add default and explicit selections in one call
            def add(*mappings)
                explicit, defaults = DependencyInjection.partition_use_arguments(*mappings)

                filtered_defaults = Set.new
                defaults.each do |obj|
                    if obj.kind_of?(DependencyInjection)
                        # Do not use merge here. One wants to override the
                        # existing selections with the new ones
                        explicit = obj.explicit.merge!(explicit)
                        filtered_defaults |= obj.defaults
                    else
                        filtered_defaults << obj
                    end
                end

                add_explicit(explicit)
                add_defaults(filtered_defaults)
                self
            end

            # Add a new dependency injection pattern to the current set
            #
            # The new mapping overrides existing mappings
            def add_explicit(mappings)
                # Invalidate the @resolved cached
                if !defaults.empty?
                    @resolved = nil
                end
                explicit.merge!(mappings) do |k, v1, v2|
                    # There is a pathological case here. If v2 == k, then we
                    # should keep the k => v1 mapping (because of recursive
                    # resolution). However, this is the one case where it does
                    # not work, as the merge! overrides the existing selection.
                    #
                    # However, when this happens, we can simply ignore the
                    # identity selection
                    if v2 == k then v1
                    else v2
                    end
                end

                @explicit = 
                    DependencyInjection.normalize_selection(
                        DependencyInjection.resolve_recursive_selection_mapping(explicit))
            end

            # True if there is an explicit selection for the given name
            def has_selection_for?(name)
                !!explicit[name]
            end

            # Normalizes an explicit selection
            #
            # The input can map any of string, Component and DataService to
            # string, Component, DataService and BoundDataService
            #
            # A normalized selection has this form:
            #
            # * string to String,Component,DataService,BoundDataService,nil
            # * Component to String,Component,nil
            # * DataService to String,DataService,BoundDataService,nil
            #
            # @raise ArgumentError if the key and value are not valid
            #   selection (see above)
            # @raise ArgumentError if the selected component or service does
            #   not fullfill the key
            # @raise AmbiguousServiceSelection if a component is selected for a
            #   data service, but there are multiple services of that type in
            #   the component
            def self.normalize_selection(selection)
                normalized = Hash.new
                selection.each do |key, value|
                    # 'key' must be one of String, Component or DataService
                    if !key.respond_to?(:to_str) &&
                        !key.kind_of?(Models::DataServiceModel) &&
                        (!key.kind_of?(Class) || !(key <= Component))

                        raise ArgumentError, "found #{value} as a selection key, but only names, component models and data service models are allowed"
                    end

                    # 'value' must be one of String,Model<Component>,Component,DataService,Model<BoundDataService>,BoundDataService or nil
                    if value &&
                        !value.respond_to?(:to_str) &&
                        !value.kind_of?(Component) &&
                        !value.kind_of?(BoundDataService) &&
                        !value.kind_of?(Models::BoundDataService) &&
                        !value.kind_of?(Models::DataServiceModel) &&
                        !value.kind_of?(InstanceRequirements) &&
                        (!value.kind_of?(Class) || !(value <= Component))
                        if value.respond_to?(:to_instance_requirements)
                            value = value.to_instance_requirements
                        else
                            raise ArgumentError, "found #{value} as a selection for #{key}, but only nil,name,component models,components,data service models and bound data services are allowed"
                        end
                    end

                    if key.respond_to?(:to_str)
                        normalized[key] = value
                        next
                    end

                    if value.respond_to?(:fullfills?)
                        if !value.fullfills?(key)
                            raise ArgumentError, "found #{value.short_name} as a selection for #{key.short_name}, but #{value.short_name} does not fullfill #{key.short_name}"
                        end
                    end

                    if key <= Component
                        if value.kind_of?(Models::BoundDataService)
                            value = value.component_model
			elsif value.kind_of?(Syskit::BoundDataService)
                            value = value.component
                        end
                        normalized[key] = value
                    elsif key <= DataService
                        if value.respond_to?(:find_data_service_from_type)
                            value = value.find_data_service_from_type(key)
                        end
                        normalized[key] = value
                    else
                        raise NotImplementedError, "should not have get there, but did"
                    end
                end
                normalized
            end

            # Add a list of objects to the default list. 
            def add_defaults(list)
                # Invalidate the @resolved cached
                @resolved = nil
                @defaults |= list
            end

            # Returns the non-ambiguous selection for the given name and
            # requirements
            #
            # @param [String,nil] name the name that should be used for
            #   resolution, or nil if there is no name
            # @param [InstanceRequirements,nil] the required models, or nil if
            #   none are specified
            # @return [InstanceSelection]
            # @raise (see #selection_for)
            def instance_selection_for(name, requirements)
                instance, component_model, selected_services = selection_for(name, requirements)
                InstanceSelection.new(instance, InstanceRequirements.from_object(component_model, requirements), requirements, selected_services)
            end

            # Returns the selected instance based on the given name and
            # requirements
            #
            # @param [String,nil] name the selection name if there is one, or nil
            # @param [InstanceRequirements] requirements the requirements for the selected
            #   instance
            # @return [(Task,Model<Component>,Hash)] the selected instance. If
            #   no matching selection is found, a matching model task proxy is
            #   created.
            # @raise [IncompatibleComponentModels] if the various selections
            #   lead to component models that are incompatible (i.e. to two
            #   component models that are different and not subclassing one
            #   another)
            def selection_for(name, requirements)
                if defaults.empty?
                    selection = self.explicit
                else
                    @resolved ||= resolve
                    return @resolved.selection_for(name, requirements)
                end

                selections = Set.new
                if name && (sel = selection[name])
                    selections << sel
                else
                    requirements.models.each do |required_m|
                        selections << [(selection[required_m] || required_m), required_m]
                    end
                end

                instance, component_model = nil, InstanceRequirements.new
                selected_services = Hash.new
                selections.each do |sel_m, required_m|
                    if sel_m.respond_to?(:to_task)
                        sel_task = sel_m.to_task
                        instance ||= sel_task
                        if instance != sel_task
                            raise ArgumentError, "task instances #{instance} and #{sel_m} are both selected for #{required_m || requirements}, but they are not compatible"
                        end
                    end

                    sel_m = sel_m.to_instance_requirements
                    if sel_m.service
                        selected_services[required_m || sel_m.service.model] = sel_m.service
                    end
                    component_model.merge(sel_m)
                end
                component_model.unselect_service

                if instance && !instance.fullfills?(component_model.base_models, component_model.arguments)
                    raise ArgumentError, "explicitly selected #{instance}, but it does not fullfill the required #{component_model}"
                end

                return instance, component_model, selected_services
            end

            # Resolves the selections by generating a direct mapping (as a hash)
            # representing the required selection
            def resolve
                result = DependencyInjection.resolve_default_selections(explicit, self.defaults)
                DependencyInjection.new(DependencyInjection.resolve_recursive_selection_mapping(result))
            end

            # Resolves a name into a component object
            #
            # @param [String] name the name to be resolved. It can be a plain
            #   name, i.e. the name of a component in 'mappings', or a
            #   name.service, i.e. the name of a service for a component in
            #   'mappings'
            # @param [Hash] mappings (see {DependencyInjection#explicit})
            # @return [#instanciate,nil] the component model or nil if the name
            #   cannot be resolved
            # @raise [NameResolutionError] if the name cannot be resolved,
            #   either because the base name does not exist or the specified
            #   service cannot be found in it
            def self.find_name_resolution(name, mappings)
                if name =~ /^(\w+)\.(.*)$/
                    object_name, service_name = $1, $2
                else
                    object_name = name
                end

                main_object = mappings[object_name]
                return if !main_object || main_object.respond_to?(:to_str)

                if service_name
                    if !main_object.respond_to?(:find_data_service)
                        raise NameResolutionError.new(object_name), "cannot select a service on #{main_object}"
                    end
                    if srv = main_object.find_data_service(service_name)
                        return srv
                    else
                        raise NameResolutionError.new(object_name), "#{main_object} has no service called #{service_name}"
                    end
                else return main_object
                end
            end

            # Recursively resolve the selections that are specified as strings
            # using the provided block
            #
            # @return [Set<String>] the set of names that could not be resolved
            def resolve_names(mapping = Hash.new)
                unresolved = Set.new
                map! do |v|
                    if v.respond_to?(:to_str)
                        result = DependencyInjection.find_name_resolution(v, mapping)
                        if !result
                            unresolved << v
                            v
                        else result
                        end

                    elsif v.respond_to?(:resolve_names)
                        # The value is e.g. an InstanceRequirements 
                        unresolved |= v.resolve_names(mapping)
                        v
                    else v
                    end
                end
                unresolved
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

            # Helper method that resolves recursive selections in a dependency
            # injection mapping
            def self.resolve_recursive_selection_mapping(spec)
                spec.map_value do |key, value|
                    resolve_selection_recursively(value, spec)
                end
            end

            # Helper method that resolves one single object recursively
            def self.resolve_selection_recursively(value, spec)
                while !value.respond_to?(:to_str) && (new_value = spec[value])
                    if value == new_value
                        return new_value
                    end
                    value = new_value
                end
                value
            end

            IGNORED_MODELS = [DataService]
            ROOT_MODELS = [TaskContext, Component, Composition]

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

                debug do
                    debug "Resolving default selections"
                    default_selections.map(&:to_s).sort.each do |sel|
                        debug "    #{sel}"
                    end
                    debug "  into"
                    using_spec.map { |k, v| [k.to_s, v.to_s] }.sort.each do |k, v|
                        debug "    #{k} => #{v}"
                    end
                    break
                end

                result = using_spec.dup

                ambiguous_default_selections = Hash.new
                resolved_default_selections = Hash.new

                default_selections.each do |selection|
                    selection = resolve_selection_recursively(selection, using_spec)
                    selection.each_fullfilled_model do |m|
                        next if IGNORED_MODELS.include?(m)
                        if selection.respond_to?(:find_all_data_services_from_type) &&
                            m.kind_of?(Models::DataServiceModel)
                            # Ignore if it is provided multiple times by the
                            # selection

                            next if selection.find_all_data_services_from_type(m).size != 1
                        end

                        break if ROOT_MODELS.include?(m)
                        if using_spec[m]
                            debug do
                                debug "  rejected #{selection.short_name}"
                                debug "    for #{m.short_name}"
                                debug "    reason: already explicitely selected"
                                break
                            end
                        elsif ambiguous_default_selections.has_key?(m)
                            ambiguity = ambiguous_default_selections[m]
                            debug do
                                debug "  rejected #{selection.short_name}"
                                debug "    for #{m.short_name}"
                                debug "    reason: ambiguity with"
                                ambiguity.each do |model|
                                    debug "      #{model.short_name}"
                                end
                                break
                            end
                            ambiguity << selection
                        elsif resolved_default_selections[m] && resolved_default_selections[m] != selection
                            removed = resolved_default_selections.delete(m)
                            ambiguous_default_selections[m] = [selection, removed].to_set
                            debug do
                                debug "  removing #{removed.short_name}"
                                debug "    for #{m.short_name}"
                                debug "    reason: ambiguity with"
                                debug "      #{selection.short_name}"
                                break
                            end
                        else
                            debug do
                                debug "  adding #{selection.short_name}"
                                debug "    for #{m.short_name}"
                                break
                            end
                            resolved_default_selections[m] = selection
                        end
                    end
                end
                debug do
                    debug "  selected defaults:"
                    resolved_default_selections.each do |key, sel|
                        debug "    #{key.respond_to?(:short_name) ? key.short_name : key}: #{sel}"
                    end
                    break
                end
                result.merge!(resolved_default_selections)
            end

            # Helper method that separates the default selections from the
            # explicit selections in the call to #use
            #
            # @return [(Hash,Set)] the explicit selections and a list of
            #     default selections
            def self.partition_use_arguments(*mappings)
                explicit = Hash.new
                defaults = Set.new
                mappings.each do |element|
                    if element.kind_of?(Hash)
                        explicit.merge!(element)
                    else
                        defaults << element
                    end
                end
                return explicit, defaults
            end

            # Merge the selections in +other+ into +self+.
            #
            # If both objects provide selections for the same keys,
            # raises ArgumentError if the two selections are incompatible
            def merge(other)
                # Invalidate the @resolved cached
                @resolved = nil
                @explicit.merge!(other.explicit) do |match, model1, model2|
                    if model1 == model2
                        model1
                    elsif model1 <= model2
                        model1
                    elsif model2 <= model1
                        model2
                    else
                        raise ArgumentError, "cannot use both #{model1} and #{model2} for #{match}"
                    end
                end
                @defaults |= other.defaults
            end
        end
end

