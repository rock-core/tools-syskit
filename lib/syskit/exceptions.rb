module Orocos
    module RobyPlugin
        class InternalError < RuntimeError; end
        class ConfigError < RuntimeError; end
        class SpecError < RuntimeError; end

        class Ambiguous < SpecError; end

        class InvalidPortMapping < SpecError; end

        # Raised when a provides declaration does not match the underlying task
        # interface
        class InvalidProvides < SpecError
            attr_reader :original_error
            attr_reader :model
            attr_reader :required_service

            def initialize(model, required_service, original_error = nil)
                @model = model
                @required_service = required_service
                @original_error   = original_error
                super()
            end

            def pretty_print(pp)
                pp.text "#{model.short_name} does not provide the '#{required_service.short_name}' service's interface"
                if original_error
                    pp.nest(2) do
                        pp.breakable
                        pp.text original_error.message
                    end
                end
            end
        end

        # Exception raised during instanciation if there is an ambiguity for a
        # composition child
        class AmbiguousIndirectCompositionSelection < Ambiguous
            attr_reader :composition_model
            attr_reader :child_name
            attr_reader :selection
            attr_reader :candidates

            def initialize(composition_model, child_name, selection, candidates)
                @composition_model = composition_model
                @child_name = child_name
                @selection  = selection
                @candidates = candidates
            end

            def pretty_print(pp)
                pp.text "ambiguity while searching for compositions for the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                pp.text "selection is:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(selection) do |keyvalue|
                        name, model = keyvalue
                        pp.text "#{name} => #{model.short_name}"
                    end
                end
                pp.breakable
                pp.text "which corresponds to the following compositions:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |model|
                        pp.text "#{model.short_name}"
                    end
                end
            end
        end

        # Exception raised when a service is required but none can be found on a
        # particular task context
        class NoMatchingService < Ambiguous
            attr_reader :composition_model
            attr_reader :child_name
            attr_reader :task_model
            attr_reader :required_service

            def initialize(composition_model, child_name, task_model, required_service)
                @composition_model, @child_name, @task_model, @required_service =
                    composition_model, child_name, task_model, required_service
            end

            def pretty_print(pp)
                pp.text "there are no services in #{task_model} that provide the service #{required_service.short_name}, to fullfill the constraints on the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                pp.text "the services of #{task_model.short_name} are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(task_model.each_data_service) do |srv|
                        pp.text "#{srv.name}: #{srv.model.short_name}"
                    end
                end
            end
        end

        # Exception raised when a service is being selected by type, but
        # multiple services are available within the component that match the
        # constraints
        class AmbiguousServiceSelection < Ambiguous
            attr_reader :task_model
            attr_reader :required_service
            attr_reader :candidates

            def initialize(task_model, required_service, candidates)
                @task_model, @required_service, @candidates =
                    task_model, required_service, candidates
            end

            def pretty_print(pp)
                pp.text "there is an ambiguity while looking for a service of type #{required_service.short_name} in #{task_model.short_name}"
                pp.breakable
                pp.text "candidates are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |service|
                        pp.text service.name
                    end
                end
            end
        end

        # Exception raised in composition instanciations if a selected component
        # model provides multipe services that fullfills a child's model 
        class AmbiguousServiceMapping < AmbiguousServiceSelection
            attr_reader :composition_model
            attr_reader :child_name

            def initialize(composition_model, child_name, task_model, required_service, candidates)
                super(task_model, required_service, candidates)
                @composition_model, @child_name =
                    composition_model, child_name
            end

            def pretty_print(pp)
                pp.text "while trying to fullfill the constraints on the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                super
            end
        end

        # Exception raised when selection facets lead to a specialization
        # selection that is incompatible
        class IncompatibleFacetedSelection < Ambiguous
            # The composition that is being selected
            attr_reader :composition
            # A mapping from a child name to its selected facet
            attr_reader :faceted_children
            # The selected specializations for each of the children, as a
            # mapping from the child name to a set of composition models
            attr_reader :specializations

            def initialize(composition, faceted_children, specializations)
                @composition, @faceted_children, @specializations =
                    composition, faceted_children.dup, specializations.dup
            end

            def pretty_print(pp) # :nodoc:
                pp.text "a set of explicit facet selections requires incompatible specializations to be selected"
                pp.breakable
                pp.text "while looking for specializations of #{composition.name}"
                pp.breakable
                pp.nest(2) do
                    pp.seplist(faceted_children) do |child_name, child_model|
                        pp.breakable
                        pp.text "child #{child_name} is using the facet #{child_model.first.selected_facet.name} of #{child_model.first.name}"
                        pp.breakable
                        pp.text "which leads to the following selected specialization(s)"
                        pp.nest(2) do
                            pp.seplist(specializations[child_name]) do |model|
                                pp.breakable
                                pp.text model.name
                            end
                        end
                    end
                end
            end
        end

        # Exception raised when we could not find concrete implementations for
        # abstract tasks that are in the plan
        class TaskAllocationFailed < SpecError
            # A task to parents mapping for the failed allocations
            attr_reader :abstract_tasks

            def initialize(tasks)
                @abstract_tasks = Hash.new

                tasks.each do |abstract_task|
                    parents = abstract_task.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[abstract_task,
                                Roby::TaskStructure::Dependency]
                            [options[:roles], parent_task]
                        end
                    abstract_tasks[abstract_task] = parents
                end
            end

            def pretty_print(pp)
                pp.text "cannot find a concrete implementation for #{abstract_tasks.size} task(s)"

                abstract_tasks.each do |task, parents|
                    pp.breakable
                    pp.text "for #{task}"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(parents) do |parent|
                            role, parent = parent
                            pp.text "child #{role.to_a.first} of #{parent.to_short_s}"
                        end
                    end
                end
            end
        end

        # Exception raised at the end of #resolve if some tasks do not have a
        # deployed equivalent
        class MissingDeployments < SpecError
            # The tasks that are not deployed, as a hash from the actual task to
            # a set of [role_set, parent_task] pairs
            #
            # This is computed in #initialize as the dependency structure will
            # probably change afterwards
            attr_reader :tasks

            def initialize(tasks, merge_graph)
                @tasks = Hash.new
                tasks.each do |task|
                    parents = task.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[task,
                                Roby::TaskStructure::Dependency]
                            [options[:roles].to_a.first, parent_task]
                        end

                    candidates = task.
                        enum_parent_objects(merge_graph).
                        find_all { |t| t.execution_agent }.
                        map { |t| t.orogen_spec.name }

                    @tasks[task] = [parents, candidates]
                end
            end

            def pretty_print(pp)
                pp.text "cannot deploy the following tasks"
                tasks.each do |task, (parents, possible_deployments)|
                    pp.breakable
                    pp.text task.to_s
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(parents) do |parent_task|
                            role, parent_task = parent_task
                            pp.text "child #{role} of #{parent_task}"
                        end
                    end
                end

                tasks.each do |task, (parents, possible_deployments)|
                    pp.breakable
                    if possible_deployments.empty?
                        pp.text "#{task}: no deployments available"
                    else
                        pp.text "#{task}: multiple possible deployments, #{possible_deployments.join(", ")}"
                    end
                end
            end
        end

        # Exception raised when the user provided a composition child selection
        # that is not compatible with the child definition
        class InvalidSelection < SpecError
            # The composition model
            attr_reader :composition_model
            # The child name for which the selection is invalid
            attr_reader :child_name
            # The model selected by the user
            attr_reader :selected_model
            # The model required by the composition for +child_name+
            attr_reader :required_models

            def initialize(composition_model, child_name, selected_model, required_models)
                @composition_model, @child_name, @selected_model, @required_models =
                    composition_model, child_name, selected_model, required_models
            end

            def pretty_print(pp)
                pp.text "cannot use #{selected_model.short_name} for the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                pp.text "it does not provide the required models"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(required_models) do |m|
                        pp.text m.short_name
                    end
                end
            end
        end

        class AmbiguousAutoConnection < Ambiguous
            # The composition model in which the automatic connection was to be
            # computed
            attr_reader :composition_model
            # The type name of the ports are involved
            attr_reader :type_name
            # The set of output candidates
            attr_reader :outputs
            # The set of input candidates
            attr_reader :inputs

            def initialize(composition_model, type_name, inputs, outputs)
                @composition_model, @type_name, @inputs, @outputs =
                    composition_model, type_name, inputs, outputs
            end

            def pretty_print_ports(pp, port_set)
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(port_set) do |port_description|
                        child_name, port_name = port_description
                        child_spec   = composition_model.find_child(child_name)
                        child_models = child_spec.models.map(&:short_name)
                        pp.text "#{child_name}.#{port_name} where"
                        pp.nest(2) do
                            pp.breakable
                            pp.text "#{child_name}'s model is #{child_models.join(", ")}"
                        end
                    end
                end
            end

            def pretty_print(pp)
                pp.text "there is an ambiguity while automatically computing connections in #{composition_model.short_name}"
                pp.breakable
                pp.text "the considered port type is #{type_name}"
                pp.breakable
                pp.text "involved outputs:"
                pretty_print_ports(pp, outputs)
                pp.breakable
                pp.text "involved inputs:"
                pretty_print_ports(pp, inputs)
            end
        end
    
        # Exception raised by CompositionModel#instanciate when multiple
        # specializations can be applied
        class AmbiguousSpecialization < Ambiguous
            # The composition model that was being instanciated
            attr_reader :composition_model
            # The user selection (see Composition.instanciate for details)
            attr_reader :selection
            # The set of possible specializations given the model and the selection
            attr_reader :candidates

            def initialize(composition_model, selection, candidates)
                @composition_model, @selection, @candidates =
                    composition_model, selection, candidates
            end

            def pretty_print(pp)
                pp.text "there is an ambiguity in the instanciation of #{composition_model.short_name}"
                pp.breakable
                if selection.empty?
                    pp.text "with no selection applied"
                else
                    pp.text "with the following selection:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(selection) do |keyvalue|
                            key, value = *keyvalue
                            if key.respond_to?(:short_name)
                                key = key.short_name
                            end
                            value = value[0]
                            if value.respond_to?(:short_name)
                                value = value.short_name
                            end

                            pp.text "#{key} => #{value}"
                        end
                    end
                end
                pp.breakable
                pp.text "the following specializations apply:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |spec|
                        pp.text spec.short_name
                    end
                end
            end
        end
    end
end


