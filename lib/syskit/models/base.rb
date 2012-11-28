module Syskit
    module Models
        # Generic module included in all classes that are used as models.
        #
        # The Roby plugin uses, as Roby does, Ruby classes as model objects. To
        # ease code reading, the model-level functionality (i.e. singleton
        # classes) are stored in separate modules whose name finishes with Model
        #
        # For instance, the singleton methods of Component are defined on
        # ComponentModel, Composition on CompositionModel and so on.
        module Base
            # Allows to set a name on private models (i.e. models that are not
            # registered as Ruby constants)
            def name=(name)
                class << self
                    attr_accessor :name
                end
                self.name = name
            end

            # [ValueSet] the set of models that are children of this one
            attribute(:submodels) { ValueSet.new }

            # Call to register a model that is a submodel of +self+
            def register_submodel(klass)
                submodels << klass
                if m = supermodel
                    m.register_submodel(klass)
                end
            end

            # Enumerates all models that are submodels of this class
            def each_submodel(&block)
                submodels.each(&block)
            end

            # Clears all registered submodels
            def clear_submodels
                children = self.submodels.dup
                deregister_submodels(children)
                children.each do |m|
                    m.clear_submodels
                end

                if m = supermodel
                    m.deregister_submodels(children)
                end
            end

            # Deregisters a set of submodels on this model and all its
            # supermodels
            #
            # This is usually not called directly. Use #clear_submodels instead
            #
            # @param [ValueSet] set the set of submodels to remove
            def deregister_submodels(set)
                current_size = submodels.size
                submodels.difference!(set)
                if (submodels.size != current_size) && (m = supermodel)
                    m.deregister_submodels(set)
                end
            end

            # Returns a string suitable to reference an element of type +self+.
            #
            # This is for instance used by the composition if no explicit name
            # is given:
            #
            #   add ElementModel
            #
            # will have a default name of
            #
            #   ElementModel.snakename
            def snakename
                name.gsub(/.*::/, '').snakecase
            end

            # Returns a string suitable to reference +self+ as a constant
            #
            # This is for instance used by SystemModel to determine what name to
            # use to export new models as constants:
            def constant_name
                name.gsub(/.*::/, '').camelcase(:upper)
            end

            # Creates a new class that is a submodel of this model
            def new_submodel
                model = self.class.new(self)
                register_submodel(model)
                if block_given?
                    model.instance_eval(&proc)
                end
                model
            end

            def short_name
                name
            end
        end


        # Validates that the given name is a valid model name. Mainly, it makes
        # sure that +name+ is a valid constant Ruby name without namespaces
        #
        # @raises ArgumentError
        def self.validate_model_name(name)
            if name =~ /::/
                raise ArgumentError, "model names cannot have sub-namespaces"
            end

            if !name.respond_to?(:to_str)
                raise ArgumentError, "expected a string as a model name, got #{name}"
            elsif !(name.camelcase(:upper) == name)
                raise ArgumentError, "#{name} is not a valid model name. Model names must start with an uppercase letter, and are usually written in UpperCamelCase"
            end
            name
        end

        # Safe port mapping merging implementation
        #
        # It verifies that there is no conflicting mappings, and if there
        # are, raises Ambiguous
        def self.merge_port_mappings(a, b)
            a.merge(b) do |source, target_a, target_b|
                if target_a != target_b
                    raise Ambiguous, "merging conflicting port mappings: #{source} => #{target_a} and #{source} => #{target_b}"
                end
                target_a
            end
        end

        # Updates the port mappings in +result+ by applying +new_mappings+
        # on +old_mappings+
        #
        # +result+ and +old_mappings+ map service models to the
        # corresponding port mappings, of the form from => to
        #
        # +new_mappings+ is a new name mapping of the form from => to
        #
        # The method updates result by applying +new_mappings+ to the +to+
        # fields in +old_mappings+, saving the resulting mappins in +result+
        def self.update_port_mappings(result, new_mappings, old_mappings)
            old_mappings.each do |service, mappings|
                updated_mappings = Hash.new
                mappings.each do |from, to|
                    updated_mappings[from] = new_mappings[to] || to
                end
                result[service] =
                    Models.merge_port_mappings(result[service] || Hash.new, updated_mappings)
            end
        end

        # Merge the given orogen interfaces into one subclass
        def self.merge_orogen_task_context_models(target, interfaces, port_mappings = Hash.new)
            interfaces.each do |i|
                if i.name
                    target.implements i.name
                end
                target.merge_ports_from(i, port_mappings)

                i.each_event_port do |port|
                    target_name = port_mappings[port.name] || port.name
                    target.port_driven target_name
                end
            end
        end
    end
end


