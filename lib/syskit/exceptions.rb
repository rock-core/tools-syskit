module Syskit
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

        # Raised when an incompatible dependency injection selection is given
        class InvalidSelection < SpecError
            # The selection key
            # @return [nil,Object]
            attr_reader :key
            # The selection
            attr_reader :selected
            # The expected model
            attr_reader :expected


            def initialize(key, selected, expected)
                @key, @selected, @expected = key, selected, expected
            end

            def pretty_print(pp)
                if key
                    pp.text "invalid selection for #{key}"
                    pp.breakable
                    pp.text "got "
                else
                    pp.text "invalid selection: got "
                end
                selected.pretty_print(pp)
                pp.breakable
                pp.text "which provides"
                pp.nest(2) do
                    selected.each_fullfilled_model do |m|
                        pp.breakable
                        m.pretty_print(pp)
                    end
                end
                pp.breakable
                pp.text "expected something that provides "
                expected.pretty_print(pp)
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

        # Exception raised when a service of a given type is required but none
        # can be found on a particular task context model
        #
        # @see UnknownServiceName, AmbiguousServiceSelection
        class NoMatchingService < Ambiguous
            # @return [Model<Component>] the component on which we were looking
            #   for a given service
            attr_reader :task_model
            # @return [Model<DataService>] the model of data service we were looking for
            attr_reader :required_service

            def initialize(task_model, required_service)
                @task_model, @required_service =
                    [*task_model], required_service
            end

            def pretty_print(pp)
                name = task_model.map(&:short_name).join(", ")
                candidates = task_model.inject([]) { |set, m| set.concat(m.each_data_service.to_a) }
                pp.text "there are no services in #{name} that provide the service #{required_service}"
                pp.breakable
                pp.text "the services of #{name} are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |srv|
                        _, srv = *srv
                        pp.text "#{srv.full_name}: #{srv.model.short_name}"
                    end
                end
            end
        end

        # Exception raised when a service of a given name is required but none
        # can be found on a particular task context model
        #
        # @see NoMatchingService, AmbiguousServiceSelection
        class UnknownServiceName < SpecError
            # @return [Model<Component>] the component on which we were looking
            #   for a given service
            attr_reader :component_model
            # @return [String] the service name
            attr_reader :service_name

            def initialize(component_model, service_name)
                @component_model, @service_name = component_model, service_name
            end

            def pretty_print(pp)
                pp.text "cannot find service #{service_name} in #{component_model.short_name}"
                pp.text "the services of #{component_model.short_name} are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(component_model.each_data_service.to_a) do |srv|
                        _, srv = *srv
                        pp.text "#{srv.full_name}: #{srv.model.short_name}"
                    end
                end
            end
        end

        # Refinement of NoMatchingService for a composition child. It adds the
        # information of the composition / child name
        class NoMatchingServiceForCompositionChild < NoMatchingService
            attr_reader :composition_model
            attr_reader :child_name

            def initialize(composition_model, child_name, task_model, required_service)
                @composition_model, @child_name = composition_model, child_name
                super(task_model, required_service)
            end

            def pretty_print(pp)
                pp.text "while trying to fullfill the constraints on the child #{child_name} of #{composition_model.short_name}"
                pp.breakable
                super
            end
        end

        # Exception raised when a service is being selected by type, but
        # multiple services are available within the component that match the
        # requested type
        #
        # @see NoMatchingService, UnknownServiceName
        class AmbiguousServiceSelection < Ambiguous
            # @return [Model<Component>] the component on which we were looking
            #   for a given service
            attr_reader :task_model
            # @return [Model<DataService>] the model of data service we were looking for
            attr_reader :required_service
            # @return [Array<Models::BoundDataService>] the set of data services
            #   that matched the requested type
            attr_reader :candidates

            def initialize(task_model, required_service, candidates)
                @task_model, @required_service, @candidates =
                    task_model, required_service, candidates
            end

            def pretty_print(pp)
                pp.text "there is an ambiguity while looking for a service of type #{required_service} in #{task_model.short_name}"
                pp.breakable
                pp.text "candidates are:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |service|
                        pp.text(service.name || service.to_s)
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

        # Exception raised during the merge steps, if a merge is possible (i.e.
        # a task provides the required service), but ambiguous
        class AmbiguousImplicitServiceSelection < AmbiguousServiceSelection
            attr_reader :task
            attr_reader :merged_task
            attr_reader :compositions

            def initialize(task, merged_task, required_service, candidates)
                super(task.model, required_service, candidates)

                @task = task
                @merged_task = merged_task
                @compositions = merged_task.parent_objects(Roby::TaskStructure::Dependency).
                    map { |parent| [parent, parent[merged_task, Roby::TaskStructure::Dependency].dup] }
            end

            def pretty_print(pp)
                pp.text "error while trying to use #{task} instead of #{merged_task}"
                pp.breakable
                pp.text "#{merged_task} is part of the following compositions:"
                pp.nest(2) do
                    pp.seplist(compositions) do |parent|
                        parent_task, dependency_options = *parent
                        pp.breakable
                        pp.text "child #{dependency_options[:roles].to_a.join(", ")} of #{parent_task}"
                    end
                end
                pp.breakable
                super
            end
        end

        # Exception raised when we could not find concrete implementations for
        # abstract tasks that are in the plan
        class TaskAllocationFailed < SpecError
            # A task to [parents, candidates] mapping for the failed allocations
            attr_reader :abstract_tasks

            # Creates a new TaskAllocationFailed exception for the given tasks.
            #
            # +tasks+ is a mapping from the abstract tasks to the possible
            # candidate implementation for these tasks, i.e.
            #
            #    t => [model0, model1, ...]
            #
            def initialize(engine, still_abstract)
                @abstract_tasks = Hash.new

                still_abstract.each do |task|
                    if task.respond_to?(:proxied_data_services)
                        candidates = task.proxied_data_services.inject(nil) do |set, m|
                            m_candidates = (engine.service_allocation_candidates[m] || Set.new).to_set
                            set ||= m_candidates
                            set & m_candidates
                        end
                        candidates ||= Set.new
                    else
                        candidates = engine.work_plan.find_local_tasks(task.concrete_model).to_set
                    end

                    parents = task.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[task,
                                Roby::TaskStructure::Dependency]
                            [options[:roles], parent_task]
                        end
                    abstract_tasks[task] = [parents, candidates]
                end
            end

            def pretty_print(pp)
                pp.text "cannot find a concrete implementation for #{abstract_tasks.size} task(s)"

                abstract_tasks.each do |task, (parents, candidates)|
                    pp.breakable
                    pp.text "#{task.to_s.gsub(/Syskit::/, '')}"
                    pp.nest(2) do
                        pp.breakable
                        if candidates
                            if candidates.empty?
                                pp.text "no candidates"
                            else
                                pp.text "#{candidates.size} candidates"
                                pp.nest(2) do
                                    pp.breakable
                                    pp.seplist(candidates) do |c_task|
                                        pp.text "#{c_task.short_name}"
                                    end
                                end
                            end
                        end
                        pp.breakable
                        pp.seplist(parents) do |parent|
                            role, parent = parent
                            pp.text "child #{role.to_a.first} of #{parent.to_s.gsub(/Syskit::/, '')}"
                        end
                    end
                end
            end
        end

        # Exception raised when we could not find devices to allocate for tasks
        # that are device drivers
        class DeviceAllocationFailed < SpecError
            # The set of tasks that failed allocation
            attr_reader :failed_tasks
            # A task to parents mapping for tasks involved in this error, at the
            # time of the exception creation
            attr_reader :task_parents
            # Existing candidates for this device
            attr_reader :candidates

            def initialize(plan, tasks)
                @failed_tasks = tasks.dup
                @candidates = Hash.new
                @task_parents = Hash.new

                tasks.each do |abstract_task|
                    resolve_device_task(plan, abstract_task)
                end
            end

            def resolve_device_task(plan, abstract_task)
                all_tasks = [abstract_task].to_set

                # List the possible candidates for the missing devices
                candidates = Hash.new
                abstract_task.model.each_master_driver_service do |srv|
                    if !abstract_task.arguments["#{srv.name}_dev"]
                        candidates[srv] = plan.find_local_tasks(srv.model).to_set
                        candidates[srv].delete(abstract_task)
                        all_tasks |= candidates[srv]
                    end
                end
                self.candidates[abstract_task] = candidates

                all_tasks.each do |t|
                    next if task_parents.has_key?(t)

                    parents = t.
                        enum_for(:each_parent_object, Roby::TaskStructure::Dependency).
                        map do |parent_task|
                            options = parent_task[t, Roby::TaskStructure::Dependency]
                            [options[:roles], parent_task]
                        end
                    task_parents[t] = parents
                end
            end

            def pretty_print(pp)
                pp.text "cannot find a device to tie to #{failed_tasks.size} task(s)"

                failed_tasks.each do |task|
                    parents = task_parents[task]
                    candidates = self.candidates[task]

                    pp.breakable
                    pp.text "for #{task.to_s.gsub(/Syskit::/, '')}"
                    pp.nest(2) do
                        if !parents.empty?
                            pp.breakable
                            pp.seplist(parents) do |parent|
                                role, parent = parent
                                pp.text "child #{role.to_a.first} of #{parent.to_s.gsub(/Syskit::/, '')}"
                            end
                        end

                        pp.breakable
                        pp.seplist(candidates) do |cand|
                            srv, tasks = *cand
                            if tasks.empty?
                                pp.text "no candidates for #{srv.short_name}"
                            else
                                pp.text "candidates for #{srv.short_name}"
                                pp.nest(2) do
                                    pp.breakable
                                    pp.seplist(tasks) do |cand_t|
                                        pp.text "#{cand_t}"
                                    end
                                end
                            end
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

            # Initializes this exception by providing a mapping from tasks that
            # have no deployments to the deployment candidates
            #
            # @param [Hash{TaskContext=>[Array<Model<Deployment>>]}] tasks_with_candidates
            def initialize(tasks_with_candidates)
                @tasks = Hash.new
                tasks_with_candidates.each do |task, candidates|
                    parents = task.dependency_context
                    candidates = candidates.map do |host, deployment, task_name, existing|
                        existing ||= Array.new
                        existing = existing.map do |task|
                            [task, task.dependency_context]
                        end
                        [host, deployment, task_name, existing]
                    end

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
                    has_free_deployment = possible_deployments.any? { |_, _, _, existing| existing.empty? }
                    pp.breakable
                    if has_free_deployment
                        pp.text "#{task}: multiple possible deployments, choose one with #prefer_deployed_tasks(deployed_task_name)"
                        current_hints = task.deployment_hints
                        if !current_hints.empty?
                            current_hints.each do |hint|
                                pp.text "  current hints: #{current_hints.map(&:to_s).join(", ")}"
                            end
                        end
                    elsif possible_deployments.empty?
                        pp.text "#{task}: no deployments available"
                    else
                        pp.text "#{task}: some deployments exist, but they are already used in this network"
                    end

                    pp.nest(2) do
                        possible_deployments.each do |host, deployment, task_name, existing|
                            pp.breakable
                            pp.text "task #{task_name} from deployment #{deployment.orogen_model.name} defined in #{deployment.orogen_model.project.name} on #{host}"
                            pp.nest(2) do
                                existing.each do |task, parents|
                                    pp.breakable
                                    msg = parents.map do |parent_task|
                                        role, parent_task = *parent_task
                                        "child #{role} of #{parent_task}"
                                    end
                                    pp.text "already used by #{task}: #{msg.join(", ")}"
                                end
                            end
                        end
                    end
                end
            end
        end

        class InstanciationError < SpecError
            # The instanciation chain, i.e. an array of composition models that
            # were being instanciated
            attr_reader :instanciation_chain

            def initialize
                @instanciation_chain = []
            end

            def pretty_print(pp)
                if !instanciation_chain.empty?
                    pp.text "while instanciating"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(instanciation_chain.reverse) do |m|
                            m.pretty_print(pp)
                        end
                    end
                end
            end
        end

        # Exception raised when the dependency injection resolves to a selection
        # that is not compatible with the expected type
        class InvalidComponentSelection < InstanciationError
            # [Model<DataService>,Model<Component>] the expected model
            attr_reader :expected_model
            # [String] the selection name
            attr_reader :name
            # [Model<DataService>,Model<Component>] the model found by the
            # dependency injection
            attr_reader :model

            def initialize(expected_model, name, model)
                @expected_model, @name, @model =
                    expected_model, name, model
            end

            def pretty_print(pp)
                pp.text "model #{expected_model.short_name} found for '#{name}' is incompatible with the expected model #{expected_model.short_name}"
            end
        end

        # Exception raised when the user provided a composition child selection
        # that is not compatible with the child definition
        class InvalidCompositionChildSelection < InstanciationError
            # The composition model
            attr_reader :composition_model
            # The child name for which the selection is invalid
            attr_reader :child_name
            # The model selected by the user
            attr_reader :selected_model
            # The model required by the composition for +child_name+
            attr_reader :required_models

            def initialize(composition_model, child_name, selected_model, required_models)
                super()
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

        # Exception raised during instanciation if a name is found that cannot
        # be resolved
        class NameResolutionError < InstanciationError
            # The names that are missing
            attr_reader :missing_names

            def initialize(missing_names)
                super()
                @missing_names =
                    if !missing_names.respond_to?(:each)
                        [missing_names]
                    else
                        missing_names.to_a
                    end
            end

            def pretty_print(pp)
                pp.text "cannot resolve the names #{missing_names.sort.join(", ")}"
                if !instanciation_chain.empty?
                    pp.breakable
                    super
                end
            end
        end

        # Raised when trying to autoconnect two objects, but no connections
        # could be found
        class InvalidAutoConnection < RuntimeError
            attr_reader :source, :sink
            def initialize(source, sink)
                @source, @sink = source, sink
            end

            def pretty_print(pp)
                pp.text "could not find any connections from #{source.short_name} to #{sink.short_name}"
                if source.respond_to?(:each_output_port)
                    pp.nest(2) do
                        pp.breakable
                        pp.text "the outputs of #{source.short_name} are"
                        pp.nest(2) do
                            pp.breakable
                            pp.seplist(source.each_output_port) do |out_p|
                                pp.text "#{out_p.name}[#{out_p.type.name}]"
                            end
                        end
                    end
                end
                if sink.respond_to?(:each_input_port)
                    pp.nest(2) do
                        pp.breakable
                        pp.text "the inputs of #{sink.short_name} are"
                        pp.nest(2) do
                            pp.breakable
                            pp.seplist(sink.each_input_port) do |in_p|
                                pp.text "#{in_p.name}[#{in_p.type.name}]"
                            end
                        end
                    end
                end
            end
        end

        # Raised when trying to compute connection between a port and a set of
        # ports (such as connecting a port to a service or component) and more
        # than one match is found
        class AmbiguousAutoConnection < Ambiguous
            # The output for which we were trying to find an input
            attr_reader :output
            # The set of input candidates
            attr_reader :input_candidates

            def initialize(output, input_candidates)
                @input_candidates, @output =
                    input_candidates, output
            end

            def pretty_print(pp)
                pp.text "there is an ambiguity while automatically connecting "
                pp.text output.short_name
                pp.breakable
                pp.text "candidates:"
                input_candidates = self.input_candidates.sort_by(&:name)
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(input_candidates) do |input_port|
                        pp.text input_port.short_name
                    end
                end
            end
        end
    
        # Exception raised by CompositionModel#instanciate when multiple
        # specializations can be applied
        class AmbiguousSpecialization < Ambiguous
            # The composition model that was being instanciated
            attr_reader :composition_model
            # @return [{String=>Model}] the specialization selector
            attr_reader :selection
            # The set of possible specializations given the model and the
            # selection. This is a list of [merged, set] tuples where +set+ is
            # a set of specializations and +merged+ the complete specialization
            # model
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
                            value = value.each_required_model
                            value = value.map do |v|
                                if v.respond_to?(:short_name) then v.short_name
                                else v.to_s
                                end
                            end

                            pp.text "#{key} => #{value.join(",")}"
                        end
                    end
                end
                pp.breakable
                pp.text "the following specializations apply:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |spec|
                        pp.text spec[0].short_name
                    end
                end
            end
        end

        # Exception raised when two lists of models cannot be merged
        #
        # See Models.merge_model_lists
        class IncompatibleComponentModels < RuntimeError
            attr_reader :model_a
            attr_reader :model_b

            def initialize(model_a, model_b)
                @model_a, @model_b = model_a, model_b
            end
            
            def pretty_print(pp)
                pp.text "models #{model_a.short_name} and #{model_b.short_name} are incompatible"
            end
        end

        # Exception raised when a connection is being created with mismatching
        # port directions
        class WrongPortConnectionDirection < RuntimeError
            attr_reader :source, :sink
            def initialize(source, sink)
                @source = source
                @sink = sink
            end

            def pretty_print(pp)
                pp.text "cannot connect #{source} to #{sink}: this is not an output-to-input connection"
            end
        end

        # Exception raised when a connection is being created with mismatching
        # port types
        class WrongPortConnectionTypes < RuntimeError
            attr_reader :source, :sink
            def initialize(source, sink)
                @source = source
                @sink = sink
            end

            def pretty_print(pp)
                pp.text "cannot connect output port #{source} to input port #{sink}: types mismatch (resp. #{source.type} and #{sink.type})"
            end
        end

        # Exception raised when a connection is being created between two ports
        # of the same component
        class SelfConnection < RuntimeError
            attr_reader :source, :sink
            def initialize(source, sink)
                @source = source
                @sink = sink
            end

            def pretty_print(pp)
                pp.text "cannot connect #{source} to #{sink}: they are ports of the same component"
            end
        end

        # Exception raised when port mappings cannot be computed because two
        # source ports have the same name
        class AmbiguousPortMappings < Ambiguous
            attr_reader :model_a
            attr_reader :model_b
            attr_reader :port_name
            def initialize(model_a, model_b, port_name)
                @model_a, @model_b, @port_name = 
                    model_a, model_b, port_name
            end

            def pretty_print(pp)
                pp.text "cannot compute port mappings: #{model_a.short_name} and #{model_b.short_name} share the same port name #{port_name}"
            end
        end

        # Exception raised in SpecializationManager when it detects that a
        # constraint added with
        # {SpecializationManager#add_specialization_constraint} is not symmetric
        class NonSymmetricSpecializationConstraint < RuntimeError
            # The constraint block
            attr_reader :validator
            # The validator arguments that trigger the bug
            attr_reader :specializations

            def initialize(validator, specializations)
                @validator, @specializations = validator, specializations
            end

            def pretty_print(pp)
                pp.text "the specialization constraint block #{validator} is not symmetric:"
                pp.breakable
                pp.text "  #{validator}[#{specializations[0]},#{specializations[1]}] => #{validator[*specializations]}"
                pp.breakable
                pp.text "  #{validator}[#{specializations[1]},#{specializations[0]}] => #{validator[*specializations.reverse]}"
            end
        end

        # Exception raised when a dynamic service block does something forbidden
        #
        # The reason is in the exception message
        class InvalidDynamicServiceBlock < RuntimeError
            attr_reader :dynamic_service
            def initialize(dynamic_service)
                @dynamic_service = dynamic_service
            end
        end

        # Exception raised when trying to refer to a port on a composite model
        # (a.k.a. proxy model, i.e. a model that refers to a task and services
        # that are not provided by this task), and both the task and the
        # services have ports with that name
        class AmbiguousPortOnCompositeModel < Ambiguous
            attr_reader :model, :models, :port_name, :candidates
            def initialize(model, models, port_name, candidates)
                @model, @models, @port_name, @candidates = model, models, port_name, candidates
            end
            def pretty_print(pp)
                pp.text "port name #{port_name} is ambiguous on #{model}"
                pp.breakable
                pp.text "it exists #{candidates.size} times:"
                pp.nest(2) do
                    pp.seplist(candidates) do |p|
                        pp.breakable
                        p.pretty_print(pp)
                    end
                end
            end
        end

        # Exception raised in {RobyApp::Configuration#use_deployment} when
        # trying to register a deployment that provides a task identical to an
        # existing task
        class TaskNameAlreadyInUse < ArgumentError
            # @return [String] the problematic task name
            attr_reader :task_name
            # @return [Models::ConfiguredDeployment] the already registered
            #   deployment
            attr_reader :existing_deployment
            # @return [Models::ConfiguredDeployment] the new deployment
            attr_reader :new_deployment

            def initialize(task_name, existing_deployment, new_deployment)
                @task_name, @existing_deployment, @new_deployment =
                    task_name, existing_deployment, new_deployment
            end

            def pretty_print(pp)
                pp.text "trying to register #{task_name} from "
                new_deployment.pretty_print(pp)
                pp.breakable
                pp.text "but it is already provided by "
                existing_deployment.pretty_print(pp)
            end
        end
end


