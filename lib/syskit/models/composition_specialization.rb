# frozen_string_literal: true

module Syskit
    module Models
        # Representation of a composition specialization
        class CompositionSpecialization
            # Additional methods that are mixed in composition specialization
            # models. I.e. composition models created by CompositionModel#specialize
            module Extension
                def is_specialization?
                    true
                end

                # The root composition model in the specialization chain
                attr_accessor :root_model
                # The set of definition blocks that have been applied on +self+ in
                # the process of specializing +root_model+
                attribute(:definition_blocks) { [] }

                # Returns the model name
                #
                # This is formatted as
                # root_model/child_name.is_a?(specialized_list),other_child.is_a?(...)
                def name
                    return super if root_model == self

                    specializations = specialized_children.map do |child_name, child_models|
                        "#{child_name}.is_a?(#{child_models.map(&:short_name).join(',')})"
                    end

                    "#{root_model.short_name}/#{specializations}"
                end

                def setup_submodel(submodel, **options)
                    submodel.root_model = submodel
                    super
                end

                # Applies the specialization block +block+ on +self+. If +recursive+
                # is true, also applies it on the children of this particular
                # specialization
                #
                # Whenever a new specialization block is applied on an existing
                # specialization, calling this method with recursive = true ensures
                # that the block is applied on all specialization models that should
                # have it applied
                def apply_specialization_block(block)
                    unless definition_blocks.include?(block)
                        instance_eval(&block)
                        definition_blocks << block
                    end
                end

                # Registers a new composition model that is a specialization of
                # +self+. The generated model is registered on the root model (not
                # this one)
                def instanciate_specialization(merged, list)
                    return super if root_model == self

                    applied_specializations.each do |s|
                        merged.merge(s)
                    end
                    list += applied_specializations.to_a
                    root_model.instanciate_specialization(merged, list)
                end
            end

            # The specialization constraints, as a map from child name to
            # set of models (data services or components)
            #
            # @return [{String=>[Model<Component>,Model<DataService>]}]
            attr_reader :specialized_children

            # The set of blocks that have been passed to the corresponding
            # specialize calls. These blocks are going to be evaluated in
            # the task model that will be created (on demand) to create
            # tasks of this specialization
            attr_reader :specialization_blocks

            # Cache of compatibilities: this is a cache of other
            # Specialization objects that can be applied at the same time
            # that this one.
            #
            # Two compositions are compatible if their specialization sets
            # are either disjoints (they don't specialize on the same
            # children) or if it is possible that a component provides both
            # the required models.
            attr_reader :compatibilities

            # The name of the composition model that is being specialized.
            #
            # It is only used for display purposes
            #
            # @return [String]
            attr_accessor :root_name

            # The composition model that can be used to instanciate this
            # specialization. This is a subclass of the composition that
            # this specialization specializes.
            attr_accessor :composition_model

            def initialize(spec = {}, block = nil)
                @specialized_children = spec
                @specialization_blocks = []
                if block
                    @specialization_blocks << block
                end
                @compatibilities = Set.new
            end

            def initialize_copy(old)
                @specialized_children = old.specialized_children.dup
                @specialization_blocks = old.specialization_blocks.dup
                @compatibilities = old.compatibilities.dup
            end

            # True if this does not specialize on anything
            def empty?
                specialized_children.empty?
            end

            def to_s
                root_name.to_s + "/" + specialized_children.map do |child_name, child_models|
                    "#{child_name}.is_a?(#{child_models.map(&:short_name).join(',')})"
                end.join(",")
            end

            # Returns true if +spec+ is compatible with +self+
            #
            # See #compatibilities for more information on compatible
            # specializations
            def compatible_with?(spec)
                empty? || spec == self || spec.empty? || compatibilities.include?(spec)
            end

            def find_specialization(child_name, model)
                if selected_models = specialized_children[child_name]
                    if matches = selected_models.find_all { |m| m.fullfills?(model) }
                        unless matches.empty?
                            matches
                        end
                    end
                end
            end

            # Returns true if +self+ specializes on +child_name+ in a way
            # that is compatible with +model+
            def has_specialization?(child_name, model)
                if selected_models = specialized_children[child_name]
                    selected_models.any? { |m| m.fullfills?(model) }
                end
            end

            # Add new specializations and blocks to +self+ without checking
            # for compatibility
            def add(new_spec, new_blocks)
                specialized_children.merge!(new_spec) do |child_name, models_a, models_b|
                    Models.merge_model_lists(models_a, models_b)
                end
                if new_blocks.respond_to?(:to_ary)
                    specialization_blocks.concat(new_blocks)
                elsif new_blocks
                    specialization_blocks << new_blocks
                end
            end

            # Create a new composition specialization object which is the merge
            # of all the given specs
            #
            # @return [CompositionSpecialization]
            def self.merge(*specs)
                composite_spec = CompositionSpecialization.new
                specs.each do |spec|
                    composite_spec.merge(spec)
                end
                composite_spec
            end

            # Merge the specialization specification of +other_spec+ into
            # +self+
            def merge(other_spec)
                @compatibilities =
                    if empty?
                        other_spec.compatibilities.dup
                    else
                        compatibilities & other_spec.compatibilities.dup
                    end
                @compatibilities << other_spec

                add(other_spec.specialized_children, other_spec.specialization_blocks)
                self
            end

            # Tests if this specialization could be used for the given
            # selection, ignoring selections that do not have a corresponding
            # entry in the specialization
            #
            # @param [{String=>Array<Model<Component>,Model<DataService>>}] selection
            # @return [Boolean]
            #
            # @example
            #   spec = CompositionSpecialization.new 'srv' => component, 'child' => composition
            #   spec.weak_match?('srv' => component) => true
            #   # assuming that 'component' does not provide 'data_service'
            #   spec.weak_match?('srv' => data_service) => false
            #
            # @see #strong_match?
            def weak_match?(selection)
                has_match = false
                result = specialized_children.all? do |child_name, child_models|
                    if this_selection = selection[child_name]
                        has_match = true
                        this_selection.fullfills?(child_models)
                    else true
                    end
                end
                has_match && result
            end

            # Tests if this specialization could be used for the given
            # selection. All the children in the selection must have a
            # corresponding entry in the specialization for this to return true
            #
            # @param [{String=>Array<Model<Component>,Model<DataService>>}] selection
            # @return [Boolean]
            #
            # @example
            #   spec = CompositionSpecialization.new 'srv' => component, 'child' => composition
            #   spec.strong_match?('srv' => component) => false
            #   spec.strong_match?('srv' => component, 'child' => composition) => true
            #   # assuming that 'component' does not provide 'data_service'
            #   spec.strong_match?('srv' => data_service, 'child' => composition) => false
            #
            # @see #weak_match?
            def strong_match?(selection)
                specialized_children.all? do |child_name, child_models|
                    if this_selection = selection[child_name]
                        this_selection.fullfills?(child_models)
                    end
                end
            end
        end
    end
end
