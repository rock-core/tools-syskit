# frozen_string_literal: true

module Syskit
    module Models
        extend Logger::Hierarchy
        extend Logger::Forward

        # Generic module included in all classes that are used as models.
        #
        # The Roby plugin uses, as Roby does, Ruby classes as model objects. To
        # ease code reading, the model-level functionality (i.e. singleton
        # classes) are stored in separate modules whose name finishes with Model
        #
        # For instance, the singleton methods of Component are defined on
        # ComponentModel, Composition on CompositionModel and so on.
        module Base
            # List of names that are valid for this model in the context of
            # DependencyInjection
            def dependency_injection_names
                []
            end

            # The model name that should be used in messages that are displayed
            # to the user. Note that Syskit defines Class#short_name as an
            # alias to #name so that #short_name can be used everywhere
            def short_name
                to_s
            end

            def to_s
                name || super
            end

            def pretty_print(pp)
                pp.text(name || "")
            end

            # Generates the InstanceRequirements object that represents +self+
            # best
            #
            # @return [Syskit::InstanceRequirements]
            def to_instance_requirements
                Syskit::InstanceRequirements.new([self])
            end
        end

        # Validates that the given name is a valid model name. Mainly, it makes
        # sure that +name+ is a valid constant Ruby name without namespaces
        #
        # @raise [ArgumentError]
        def self.validate_model_name(name)
            if name =~ /::/
                raise ArgumentError, "model names cannot have sub-namespaces"
            end

            if !name.respond_to?(:to_str)
                raise ArgumentError, "expected a string as a model name, got #{name}"
            elsif name.camelcase(:upper) != name
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
                updated_mappings = {}
                mappings.each do |from, to|
                    updated_mappings[from] = new_mappings[to] || to
                end
                result[service] =
                    Models.merge_port_mappings(result[service] || {}, updated_mappings)
            end
        end

        # Merge the given orogen interfaces into one subclass
        def self.merge_orogen_task_context_models(target, interfaces, port_mappings = {})
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

        # Merges two lists of models into a single one.
        #
        # The resulting list can only have a single class object. Modules
        # that are already included in these classes get removed from the
        # list as well
        #
        # @raise [IncompatibleModelLists] if the two lists contain incompatible
        #   models
        def self.merge_model_lists(a, b)
            a_classes, a_modules = a.partition { |k| k.kind_of?(Class) }
            b_classes, b_modules = b.partition { |k| k.kind_of?(Class) }

            klass = a_classes.first || b_classes.first
            a_classes.concat(b_classes).each do |k|
                if k < klass
                    klass = k
                elsif !(klass <= k) # rubocop:disable Style/InverseMethods
                    raise IncompatibleComponentModels.new(k, klass),
                          "models #{k.short_name} and #{klass.short_name} are not compatible"
                end
            end

            result = Set.new
            result << klass if klass
            a_modules.concat(b_modules).each do |m|
                do_include = true
                result.delete_if do |other_m|
                    do_include &&= !(other_m <= m) # rubocop:disable Style/InverseMethods
                    m < other_m
                end
                result << m if do_include
            end
            result
        end

        def self.is_model?(m)
            m.kind_of?(Syskit::Models::Base)
        end

        def self.create_orogen_task_context_model(*args)
            OroGen::Spec::TaskContext.new(Roby.app.default_orogen_project, *args)
        end

        def self.create_orogen_deployment_model(*args)
            OroGen::Spec::Deployment.new(Roby.app.default_orogen_project, *args)
        end
    end
end
