# frozen_string_literal: true

module Syskit
    # Representation and manipulation of dependency injection selection
    class DependencyInjection
        extend Logger::Hierarchy
        extend Logger::Forward

        attr_reader :explicit
        attr_reader :defaults

        def hash
            [explicit, defaults].hash
        end

        def eql?(other)
            other.kind_of?(DependencyInjection) &&
                explicit == other.explicit &&
                defaults == other.defaults
        end

        def ==(other)
            eql?(other)
        end

        # creates a new DependencyInjection instance
        #
        # If arguments are provided, they must match the format expected by
        # #add
        def initialize(*base)
            @explicit = {}
            @defaults = Set.new
            add(*base) unless base.empty?
        end

        attr_reader :resolved

        def initialize_copy(from)
            super
            @explicit = from.explicit.dup
            @defaults = from.defaults.dup
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
            explicit =
                self.explicit
                    .map { |k, v| [k.to_s, v.to_s] }
                    .sort_by(&:first)
                    .map { |k, v| "#{k} => #{v}" }
            defaults = self.defaults.map(&:to_s)
            defaults.concat(explicit).join(", ")
        end

        def pretty_print(pp)
            pp.text "DependencyInjection"

            pp.breakable
            pp.text "Explicit:"
            unless explicit.empty?
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
            unless defaults.empty?
                pp.nest(2) do
                    pp.breakable
                    defaults = self.defaults.map(&:to_s).sort
                    pp.seplist(defaults) do |v|
                        pp.text v.to_s
                    end
                end
            end

            nil
        end

        # @overload add(default0, default1, key0 => value0)
        # @overload add([default0, default1], key0 => value0)
        # @overload add(dependency_injection)
        #
        # Add default and explicit selections in one call
        def add(*mappings)
            explicit, defaults =
                DependencyInjection.partition_use_arguments(*mappings)
            explicit = DependencyInjection.normalize_selection(explicit)

            filtered_defaults = Set.new
            defaults.each do |obj|
                if obj.kind_of?(DependencyInjection)
                    # Do not use merge here. One wants to override the
                    # existing selections with the new ones
                    explicit = obj.explicit.merge!(explicit)
                    filtered_defaults |= obj.defaults
                else
                    filtered_defaults <<
                        DependencyInjection.normalize_selected_object(obj)
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
            @resolved = nil unless defaults.empty?
            mappings.each_value do |v|
                v.freeze if v.kind_of?(InstanceRequirements)
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
                DependencyInjection.resolve_recursive_selection_mapping(explicit)
        end

        def add_mask(mask)
            mask.each do |key|
                explicit[key] = DependencyInjection.do_not_inherit
            end
        end

        # True if there is an explicit selection for the given name
        def has_selection_for?(name)
            direct_selection_for(name)
        end

        # Normalizes an explicit selection
        #
        # The input can map any of string, Component and DataService to
        # string, Component, DataService and BoundDataService
        #
        # A normalized selection has this form:
        #
        # * string to String,{Component},{DataService},{BoundDataService},
        #   {.do_not_inherit},{.nothing}
        # * Component to String,{Component},{.do_not_inherit},{.nothing}
        # * DataService to String,{DataService},{BoundDataService},
        #   {.do_not_inherit},{.nothing}
        #
        # @raise ArgumentError if the key and value are not valid
        #   selection (see above)
        # @raise ArgumentError if the selected component or service does
        #   not fullfill the key
        # @raise AmbiguousServiceSelection if a component is selected for a
        #   data service, but there are multiple services of that type in
        #   the component
        def self.normalize_selection(selection)
            normalized = {}
            selection.each do |key, value|
                # 'key' must be one of String, Component or DataService
                if !key.respond_to?(:to_str) &&
                   !key.kind_of?(Models::DataServiceModel) &&
                   (!key.kind_of?(Class) || !(key <= Component))

                    raise ArgumentError,
                          'found #{value} as a selection key, but only names, '\
                          "component models and data service models are allowed"
                end

                # 'value' must be one of String,Model<Component>,
                # Component, DataService, Model<BoundDataService>,
                # BoundDataService or nil
                value = normalize_selected_object(value, key)

                if key.respond_to?(:to_str)
                    normalized[key] = value
                    next
                end

                if value.respond_to?(:fullfills?)
                    unless value.fullfills?(key)
                        raise ArgumentError,
                              "found #{value.name}(of class #{value.class}) "\
                              "as a selection for #{key.name}, but "\
                              "#{value.name} does not fullfill #{key.name}"
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
                    raise NotImplementedError,
                          "should not have get there, but did"
                end
            end
            normalized
        end

        # Add a list of objects to the default list.
        def add_defaults(list)
            # Invalidate the @resolved cached
            @resolved = nil
            list.each { |v| v.freeze if v.kind_of?(InstanceRequirements) }
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
            instance, component_model, selected_services, used_keys =
                selection_for(name, requirements)
            selection = InstanceSelection.new(
                instance,
                InstanceRequirements.from_object(component_model, requirements),
                requirements,
                selected_services
            )
            [selection, used_keys]
        end

        def direct_selection_for(obj)
            if defaults.empty?
                if (sel = explicit[obj]) && sel != DependencyInjection.do_not_inherit
                    sel
                end
            else
                @resolved ||= resolve
                @resolved.direct_selection_for(obj)
            end
        end

        # Returns the selected instance based on the given name and
        # requirements
        #
        # @param [String,nil] name the selection name if there is one, or nil
        # @param [InstanceRequirements] requirements the requirements for the selected
        #   instance
        # @return
        # [(Task,Model<Component>,Hash<Model<DataService>,
        #  Models::BoundDataService>,Set<Object>)] the selected instance.
        #   If no matching selection is found, a matching model task proxy
        #   is created. The first hash is a service mapping, from requested
        #   service models to bound services in the task model. Finally, the
        #   last set is the set of keys that have been used for the resolution.
        # @raise [IncompatibleComponentModels] if the various selections
        #   lead to component models that are incompatible (i.e. to two
        #   component models that are different and not subclassing one
        #   another)
        def selection_for(name, requirements)
            if defaults.empty?
                selection = explicit
            else
                @resolved ||= resolve
                return @resolved.selection_for(name, requirements)
            end

            used_keys = Set.new
            selections = Set.new
            selected_services = {}
            if name && (sel = selection[name]) &&
               (sel != DependencyInjection.do_not_inherit)
                used_keys << name
                sel = requirements if sel == DependencyInjection.nothing
                selections << [sel]
                selection.each do |key, value|
                    if !value.respond_to?(:component_model) ||
                       value.component_model != sel
                        next
                    end

                    requirements.each_required_model do |req_m|
                        if key.respond_to?(:fullfills?) && key.fullfills?(req_m)
                            selected_services[req_m] ||= value
                        end
                    end
                end
            else
                requirements.each_required_model do |required_m|
                    if (sel = direct_selection_for(required_m))
                        selections << [sel, required_m]
                        used_keys << required_m
                    else
                        selections << [required_m, required_m]
                    end
                end
            end

            selected_instance = nil
            selected_requirements = InstanceRequirements.new
            requirements_name = nil
            selections.each do |sel_m, required_m|
                if sel_m.respond_to?(:to_task)
                    sel_task = sel_m.to_task
                    selected_instance ||= sel_task
                    if selected_instance != sel_task
                        raise ArgumentError,
                              "task instances #{selected_instance} and #{sel_m} "\
                              "are both selected for #{required_m || requirements}, "\
                              "but they are not compatible"
                    end
                end

                sel_m = sel_m.to_instance_requirements
                requirements_name ||= sel_m.name if sel_m.respond_to?(:name)
                if sel_m.service
                    if required_m
                        selected_services[required_m] = sel_m.service
                    else
                        requirements.each_required_model do |req_m|
                            if sel_m.fullfills?(req_m)
                                selected_services[req_m] ||= sel_m.service
                            end
                        end
                    end
                end
                selected_requirements.merge(
                    sel_m.to_component_model, keep_abstract: true
                )
            end
            selected_requirements.name = requirements_name if selections.size == 1

            valid_selected_instance =
                !selected_instance ||
                selected_instance.fullfills?(requirements, requirements.arguments)
            unless valid_selected_instance
                raise ArgumentError,
                      "explicitly selected #{selected_instance}, "\
                      "but it does not fullfill the required #{requirements}"
            end

            [selected_instance, selected_requirements, selected_services, used_keys]
        end

        def resolve_default_selections
            @explicit = DependencyInjection
                        .resolve_default_selections(explicit, defaults)
            defaults.clear
        end

        def resolve!
            resolve_default_selections
            @explicit = DependencyInjection
                        .resolve_recursive_selection_mapping(explicit)
        end

        # Resolves the selections by generating a direct mapping (as a hash)
        # representing the required selection
        def resolve
            result = dup
            result.resolve!
            result
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
            if (m = /^(\w+)\.(.*)$/.match(name))
                object_name = m[1]
                service_name = m[2]
            else
                object_name = name
            end

            main_object = mappings[object_name]
            return if !main_object || main_object.respond_to?(:to_str)

            return main_object unless service_name

            unless main_object.respond_to?(:find_data_service)
                raise NameResolutionError.new(object_name),
                      "cannot select a service on #{main_object}"
            end

            srv = main_object.find_data_service(service_name)
            unless srv
                raise NameResolutionError.new(object_name),
                      "#{main_object} has no service called #{service_name}"
            end

            srv
        end

        # Recursively resolve the selections that are specified as strings
        # using the provided block
        #
        # @return [Set<String>] the set of names that could not be resolved
        def resolve_names(mapping = {})
            unresolved = Set.new
            map! do |v|
                if v.respond_to?(:to_str)
                    result = DependencyInjection
                             .find_name_resolution(v, mapping)
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
        def map!
            # Invalidate the @resolved cached
            @resolved = nil
            changed = false
            explicit = self.explicit.transform_values do |v|
                result = yield(v)
                changed ||= (result != v)
                result
            end
            if changed
                @explicit = DependencyInjection
                            .resolve_recursive_selection_mapping(explicit)
            end

            @defaults.map! do |v|
                yield(v)
            end
            self
        end

        # Enumerates the selected objects (not the keys)
        def each(&block)
            return enum_for(__method__) unless block_given?

            explicit.each_value(&block)
            defaults.each(&block)
            self
        end

        def each_selection_key(&block)
            explicit.each_key(&block)
        end

        class SpecialDIValue
            def initialize(name)
                @name = name
            end

            def to_s
                "DependencyInjection.#{@name}"
            end

            def inspect
                to_s
            end
        end

        def self.do_not_inherit
            @do_not_inherit ||= SpecialDIValue.new("do_not_inherit")
        end

        def self.nothing
            @nothing ||= SpecialDIValue.new("nothing")
        end

        # Helper method that resolves recursive selections in a dependency
        # injection mapping
        def self.resolve_recursive_selection_mapping(spec)
            spec.transform_values do |value|
                resolve_selection_recursively(value, spec)
            end
        end

        # Helper method that resolves one single object recursively
        def self.resolve_selection_recursively(value, spec)
            while value && !value.respond_to?(:to_str)
                case value
                when Models::BoundDataService
                    return value unless value.component_model.kind_of?(Class)

                    component_model = value.component_model
                    if (selected = spec[component_model]) &&
                       !selected.respond_to?(:to_str)
                        if selected != component_model
                            new_value = selected.selected_for(value).selected_model
                        end
                    end
                when Module
                    new_value = spec[value]
                else return value
                end

                return value if !new_value || (value == new_value)

                value = new_value
            end
            value
        end

        IGNORED_MODELS = [
            DataService, TaskContext, Component, Composition,
            Roby::Task, Roby::TaskService
        ].freeze

        def self.normalize_selected_object(value, key = nil)
            unless value
                raise ArgumentError,
                      "found nil as selection for #{key}, "\
                      "but it is not an acceptable selection value anymore"
            end

            value = value.component || value.selected if value.kind_of?(InstanceSelection)

            # 'value' must be one of String, Model<Component>, Component,
            # DataService, Model<BoundDataService>, BoundDataService
            if !value.respond_to?(:to_str) &&
               !value.kind_of?(SpecialDIValue) &&
               !value.kind_of?(Component) &&
               !value.kind_of?(BoundDataService) &&
               !value.kind_of?(Models::BoundDataService) &&
               !value.kind_of?(Models::DataServiceModel) &&
               !value.kind_of?(InstanceRequirements) &&
               (!value.kind_of?(Class) || !(value <= Component))
                if value.respond_to?(:to_instance_requirements)
                    value = value.to_instance_requirements
                elsif key
                    raise ArgumentError,
                          "found #{value}(of class #{value.class}) as a selection "\
                          "for #{key}, but only names, component models, "\
                          "components, data service models and bound data services "\
                          "are allowed"
                else
                    raise ArgumentError,
                          "found #{value}(of class #{value.class}) as a selection, "\
                          "for #{key}, but only names, component models, "\
                          "components, data service models and bound data services "\
                          "are allowed"
                end
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
            return using_spec if !default_selections || default_selections.empty?

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

            ambiguous_default_selections = {}
            resolved_default_selections = {}

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

                    if using_spec[m]
                        debug do
                            debug "  rejected #{selection.short_name}"
                            debug "    for #{m.short_name}"
                            debug "    reason: already explicitely selected"
                            break
                        end
                    elsif ambiguous_default_selections.key?(m)
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
                    elsif resolved_default_selections[m] &&
                          resolved_default_selections[m] != selection
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
                    key_name = key.respond_to?(:name) ? key.name : key
                    debug "    #{key_name}: #{sel}"
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
            explicit = {}
            defaults = Set.new
            mappings.each do |element|
                if element.kind_of?(Hash)
                    explicit.merge!(element)
                else
                    defaults << element
                end
            end
            [explicit, defaults]
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
                elsif model1.fullfills?(model2)
                    model1
                elsif model2.fullfills?(model1)
                    model2
                else
                    raise ArgumentError,
                          "cannot use both #{model1} and #{model2} for #{match}"
                end
            end
            @defaults |= other.defaults
        end
    end
end
