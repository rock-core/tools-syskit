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
            # All models are defined in the context of a SystemModel instance.
            # This is this instance
            attr_accessor :system_model

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

            def to_s # :nodoc:
                supermodels = ancestors.map(&:name)
                i = supermodels.index("Syskit::Component")
                supermodels = supermodels[0, i]
                supermodels = supermodels.map do |name|
                    name.gsub(/Syskit::(.*)/, "\\1") if name
                end
                "#<#{supermodels.join(" < ")}>"
            end

            # Creates a new class that is a submodel of this model
            def new_submodel(name = nil)
                klass = Class.new(self)
                klass.system_model = system_model
                if name
                    klass.instance_variable_set :@name, name
                end
                klass
            end

            def self.validate_service_model(model, system_model, expected_type = DataService)
                if !model.kind_of?(DataServiceModel)
                    raise ArgumentError, "expected a data service, source or combus model, got #{model} of type #{model.class}"
                elsif !(model < expected_type)
                    # Try harder. This is meant for DSL loading, as we define
                    # data services for devices and so on
                    if query_method = SystemModel::MODEL_QUERY_METHODS[expected_type]
                        model = system_model.send(query_method, model.name)
                    end
                    if !model
                        raise ArgumentError, "expected a submodel of #{expected_type.short_name} but got #{model} of type #{model.class}"
                    end
                end
                model
            end

            PREFIX_SHORTCUTS =
                { 'Devices' => %w{Devices Dev},
                  'DataService' => %w{DataService Srv} }

            def self.validate_model_name(prefix, user_name)
                name = user_name.dup
                PREFIX_SHORTCUTS[prefix].each do |str|
                    name.gsub!(/^#{str}::/, '')
                end
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

            def short_name
                if name
                    name.gsub('Syskit::', '').
                        gsub('DataServices', 'Srv').
                        gsub('Devices', 'Dev').
                        gsub('Compositions', 'Cmp')
                end
            end
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
    end
end


