# frozen_string_literal: true

module Syskit
    module Models
        # Model-level instances and attributes for compositions
        #
        # See the documentation of Model for an explanation of the *Model
        # modules.
        module Composition
            include Models::Base
            include Models::PortAccess
            include Models::Component

            # @return [SpecializationManager] the object that manages all
            #   specializations defined on this composition model
            attribute(:specializations) { SpecializationManager.new(self) }

            def promote_child(child_name, child)
                promoted = child.attach(self)
                promoted.parent_model = child
                children[child_name] = promoted
            end

            # The composition children
            #
            # @key_name child_name
            # @return [Hash<String,CompositionChild>]
            inherited_attribute(:child, :children, map: true) do
                {}
            end

            inherited_attribute(:child_constraint, :child_constraints, map: true) do
                Hash.new { |h, k| h[k] = [] }
            end

            def clear_model
                super
                child_constraints.clear
                children.clear
                configurations.clear
                exported_inputs.clear
                exported_outputs.clear
                @specializations = SpecializationManager.new(self)
                @main_task = nil
            end

            # Method that maps connections from this composition's parent models
            # to this composition's own interface
            #
            # It is called as needed when calling {#each_explicit_connection}
            def promote_explicit_connection(connections)
                (child_out_name, child_in_name), mappings = *connections

                mappings_out =
                    if (child_out = children[child_out_name])
                        child_out.port_mappings
                    else {}
                    end
                mappings_in =
                    if (child_in = children[child_in_name])
                        child_in.port_mappings
                    else {}
                    end

                mapped = {}
                mappings.each do |(port_name_out, port_name_in), options|
                    port_name_out = (mappings_out[port_name_out] || port_name_out)
                    port_name_in  = (mappings_in[port_name_in]   || port_name_in)
                    mapped[[port_name_out, port_name_in]] = options
                end
                [[child_out_name, child_in_name], mapped]
            end

            # The set of connections specified by the user for this composition
            #
            # @return [Hash{(String,String)=>{(String,String)=>Hash}}] the set
            # of connections defined on this composition model. The first level
            # is a mapping from the (output child name, input child name) to a
            # set of connections. The set of connections is specified as a
            # mapping from the output port name (on the output child) and the
            # input port name (on the input child) to the desired connection policy.
            #
            # Empty connection policies means "autodetect policy"
            inherited_attribute(:explicit_connection, :explicit_connections) do
                Hash.new { |h, k| h[k] = {} }
            end

            # [Set<Model<Composition>>] the composition models that are parent to this one
            attribute(:parent_models) { Set.new }

            # The root composition model in the specialization hierarchy
            def root_model
                self
            end

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            #
            # It is empty for composition models that are not specializations
            attribute(:specialized_children) do
                {}
            end

            ##
            # :attr: specialized_children
            #
            # The set of specializations that are applied from the root of the
            # model graph up to this model
            attribute(:applied_specializations) { Set.new }

            # Called by {Component.specialize} to create the composition model
            # that will be used for a private specialization
            def create_private_specialization
                new_submodel(register_specializations: false)
            end

            # (see SpecializationManager#specialize)
            def specialize(options = {}, &block)
                return super(options) if options.respond_to?(:to_str)
                return super() if options.empty?

                options = options.transform_keys do |key|
                    if key.respond_to?(:to_str) || key.respond_to?(:to_sym)
                        Roby.warn_deprecated "calling #specialize with child names "\
                                             "is deprecated, use _child accessors "\
                                             "instead (i.e. #{key}_child here)", 5
                        key
                    elsif key.respond_to?(:child_name)
                        key.child_name
                    end
                end

                specializations.specialize(options, &block)
            end

            # Returns true if this composition model is a model created by
            # specializing another one on +child_name+ with +child_model+
            #
            # For instance:
            #
            #   composition 'Compo' do
            #       add Source
            #       add Sink
            #
            #       submodel = specialize Sink, Logger
            #
            #       submodel.specialized_on?('Sink', Logger) # => true
            #       submodel.specialized_on?('Sink', Test) # => false
            #       submodel.specialized_on?('Source', Logger) # => false
            #   end
            def specialized_on?(child_name, child_model)
                specialized_children.key?(child_name) &&
                    specialized_children[child_name].include?(child_model)
            end

            # Returns true if +self+ is a parent model of +child_model+
            def parent_model_of?(child_model)
                (child_model < self) ||
                    specializations.values.include?(child_model)
            end

            # Internal helper to add a child to the composition
            def add_child(name, child_models, dependency_options)
                name = name.to_str
                dependency_options = Roby::TaskStructure::Dependency
                                     .validate_options(dependency_options)

                # We do NOT check for an already existing definition. The reason
                # is that specialization (among other) will add a default child,
                # that may be overriden by the composition's owner. Either to
                # set arguments, or to have a specialization over an aspect of a
                # data service use a more specific task model in the specialized
                # composition.
                #
                # Anyway, the remainder checks that the new definition is a
                # valid overloading of the previous one.

                child_model = find_child(name) || CompositionChild.new(self, name)
                # The user might have called e.g.
                #
                #   overload 'bla', bla_child.with_arguments(bla: 10)
                if child_models.object_id != child_model.object_id
                    child_model.merge(child_models)
                end
                dependency_options =
                    Roby::TaskStructure::Dependency
                    .merge_dependency_options(child_model.dependency_options,
                                              dependency_options)
                child_model.dependency_options.clear
                child_model.dependency_options.merge!(dependency_options)

                Models.debug do
                    Models.debug "added child #{name} to #{short_name}"
                    Models.debug "  with models #{child_model.model}"
                    if (parent_model = superclass.find_child(name))
                        Models.debug "  updated from #{parent_model.model}"
                    end
                    unless child_model.port_mappings.empty?
                        Models.debug "  port mappings"
                        Models.log_nest(4) do
                            child_model.port_mappings.each_value do |mappings|
                                Models.log_pp(:debug, mappings)
                            end
                        end
                    end
                    break
                end
                children[name] = child_model

                @exported_outputs = exported_outputs.transform_values do |port|
                    if port.component_model.child_name == name
                        child_model.find_port(port.name)
                    else port
                    end
                end
                @exported_inputs = exported_inputs.transform_values do |port|
                    if port.component_model.child_name == name
                        child_model.find_port(port.name)
                    else port
                    end
                end

                child_model
            end

            # Overloads an existing child with a new model and/or options
            #
            # This is 100% equivalent to
            #
            #   add model, (:as => name).merge(options)
            #
            # The only (important) difference is that it checks that +name+ is
            # indeed an existing child, and allows people that read the
            # composition model to understand the intent
            def overload(child, model, **options)
                child = child.child_name if child.respond_to?(:child_name)
                unless find_child(child)
                    raise ArgumentError, "#{child} is not an existing child "\
                                         "of #{short_name}"
                end

                add(model, **options.merge(as: child))
            end

            # Add an element in this composition.
            #
            # @param [Array<Model>,Model] models the child's model. Can be a set
            #   of models to provide e.g. multiple unrelated data services, or a
            #   task context and a data service type that would be provided by a
            #   dynamic data service on the task context.
            # @param [Hash] options set of options for the new child, as well as
            #   any option that is valid to be passed to Roby::Task#depends_on
            # @option options [String] :as this is actually mandatory, but is
            #   keps as an option for backward compatibility reasons. It is the
            #   name of the child. The new child can be accessed by calling
            #   #childname_child on the new model (see example below)
            # @return [CompositionChild]
            #
            # @example
            #   data_service_type 'OrientationSrv'
            #   class OrientationFilter < Syskit::Composition
            #     # Add a child called 'orientation'
            #     add OrientationSrv, :as => 'orientation'
            #   end
            #   # Returns the object that defines the new child
            #   Orientation.orientation_child
            #
            # == Subclassing
            #
            # If the composition model is a subclass of another composition
            # model, then +add+ can be used to override a child definition. In
            # if it the case, if +model+ is a component model, then it has to be
            # a subclass of any component model that has been used in the parent
            # composition. Otherwise, #add raises ArgumentError
            #
            # @example overloading a child with an unrelated data service
            #
            #   data_service_type "RawImuReadings"
            #   class Foo < Orientation
            #     # This is fine as +raw_imu_readings+ and +orientation_provider+
            #     # can be combined. +submodel+ will require 'imu' to provide both
            #     # a RawImuReadings data service and a Orientation data service.
            #     add RawImuReadings, :as => 'imu'
            #   end
            #
            # @example overloading a child with an incompatible task model
            #
            #   class Foo < Syskit::Composition
            #     add XsensImu::Task, :as => 'imu'
            #   end
            #   class Bar < Foo
            #     # This overload is invalid if the two tasks are unrelated
            #     # (i.e. if DfkiImu::Task is not a subclass of XsensImu::Task)
            #     add DfkiImu::Task, :as => 'imu'
            #   end
            #
            def add(models, as: nil, **dependency_options)
                models =
                    if models.respond_to?(:to_instance_requirements)
                        models.to_instance_requirements
                    else
                        InstanceRequirements.new(Array(models))
                    end

                unless as
                    raise ArgumentError, "you must provide an explicit name with "\
                                         "the :as option"
                end

                add_child(as, models, dependency_options)
            end

            # Add a child that may not be provided
            #
            # (see #add)
            def add_optional(models, **options)
                child = add(models, **options)
                child.optional
                child
            end

            # Returns this composition's main task
            #
            # The main task is the task that performs the composition's main
            # goal (if there is one). The composition will terminate
            # successfully whenever the main task finishes successfully.
            def main_task
                if @main_task then @main_task
                elsif superclass.respond_to?(:main_task)
                    superclass.main_task
                end
            end

            # DEPRECATED. Use #add_main instead.
            def add_main_task(models, **options) # :nodoc:
                add_main(models, **options)
            end

            # Adds the given child, and marks it as the task that provides the
            # main composition's functionality.
            #
            # What is means in practice is that the composition will terminate
            # successfully when this child terminates successfully
            def add_main(models, **options)
                if main_task
                    raise ArgumentError, "this composition already has a main task child"
                end

                @main_task = add(models, **options)
            end

            # Returns true if this composition model is a specialized version of
            # its superclass, and false otherwise
            def is_specialization?
                false
            end

            def pretty_print(pp) # :nodoc:
                pp.text "#{root_model.name}:"

                specializations = specialized_children.to_a
                unless specializations.empty?
                    pp.text "Specialized on:"
                    pp.nest(2) do
                        specializations.each do |key, selected_models|
                            pp.breakable
                            pp.text "#{key}: "
                            pp.nest(2) do
                                pp.seplist(selected_models) do |m|
                                    m.pretty_print(pp)
                                end
                            end
                        end
                    end
                end

                data_services = each_data_service.to_a
                return if data_services.empty?

                pp.nest(2) do
                    pp.breakable
                    pp.text "Data services:"
                    pp.nest(2) do
                        data_services.sort_by(&:first)
                                     .each do |name, ds|
                                         pp.breakable
                                         pp.text "#{name}: #{ds.model.name}"
                                     end
                    end
                end
            end

            # Returns the set of connections that should be created during the
            # instanciation of this composition model.
            #
            # The returned value is a mapping:
            #
            #   [source_name, sink_name] =>
            #       {
            #           [source_port_name0, sink_port_name1] => connection_policy,
            #           [source_port_name0, sink_port_name1] => connection_policy
            #       }
            #
            def connections
                result = Hash.new { |h, k| h[k] = {} }

                # In the following, 'key' is [child_source, child_dest] and
                # 'mappings' is [port_source, port_sink] => connection_policy
                each_explicit_connection do |key, mappings|
                    result[key].merge!(mappings)
                end
                result
            end

            # Tests whether the given port is a port of one of this
            # composition's children
            def child_port?(port)
                port_component_model = port.to_component_port.component_model
                port_component_model.respond_to?(:composition_model) &&
                    port_component_model.composition_model == self
            end

            # Export the given port to the boundary of the composition (it
            # becomes a composition port). By default, the composition port has
            # the same name than the exported port. This name can be overriden
            # by the :as option
            #
            # For example, if one does:
            #
            #    composition 'Test' do
            #       source = add 'Source'
            #       export source.output
            #       export source.output, :as => 'output2'
            #    end
            #
            # Then the resulting composition gets 'output' and 'output2' output
            # ports that can further be used in other connections (or
            # autoconnections):
            #
            #    composition 'Global' do
            #       test = add 'Test'
            #       c = add 'Component'
            #       connect test.output2 => c.input
            #    end
            #
            def export(port, as: port.name)
                name = as.to_str
                existing = find_exported_input(name) || find_exported_output(name)
                if existing
                    if port.to_component_port != existing
                        raise ArgumentError, "#{port} is already exported as #{name} "\
                                             "on #{short_name}, cannot override "\
                                             "with #{port}."
                    end
                    return
                end

                unless child_port?(port)
                    raise ArgumentError, "#{port} is not a port of one of "\
                                         "#{self}'s children"
                end

                case port
                when InputPort
                    exported_inputs[name] = port.to_component_port
                when OutputPort
                    exported_outputs[name] = port.to_component_port
                else
                    raise TypeError, "invalid attempt to export port #{port} "\
                                     "of type #{port.class}"
                end
                find_port(name)
            end

            # Returns true if +port_model+, which has to be a child's port, is
            # exported in this composition
            #
            # @return [Boolean]
            # @see #export
            #
            # @example
            #
            #   class C < Syskit::Composition
            #     add srv, :as => 'srv'
            #     export srv.output_port
            #   end
            #
            #   C.exported_port?(C.srv_child.output_port) => true
            #
            def exported_port?(port)
                each_exported_output do |_name, p|
                    return true if p == port
                end
                each_exported_input do |_name, p|
                    return true if p == port
                end
                false
            end

            # Enumerates this component's output ports
            def each_output_port
                return enum_for(:each_output_port) unless block_given?

                each_exported_output do |name, _p|
                    yield(find_output_port(name))
                end
            end

            # Enumerates this component's input ports
            def each_input_port
                return enum_for(:each_input_port) unless block_given?

                each_exported_input do |name, _p|
                    yield(find_input_port(name))
                end
            end

            # Returns the composition's output port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_output_port(name)
                name = name.to_str
                return unless (p = find_exported_output(name.to_str))

                OutputPort.new(self, p.orogen_model, name)
            end

            # Returns the composition's input port named 'name'
            #
            # See #port, and #export to create ports on a composition
            def find_input_port(name)
                name = name.to_str
                return unless (p = find_exported_input(name.to_str))

                InputPort.new(self, p.orogen_model, name)
            end

            # Returns true if +name+ is a valid dynamic input port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_input_port?(_name, _type = nil)
                false
            end

            # Returns true if +name+ is a valid dynamic output port.
            #
            # On a composition, it always returns false. This method is defined
            # for consistency for the other kinds of Component objects.
            def has_dynamic_output_port?(_name, _type = nil)
                false
            end

            # @api private
            #
            # Context object under which the dynamic data service blocks are
            # evaluated
            #
            # The composition's version adds the ability to access the children
            # and require dynamic services on them
            class DynamicServiceInstantiationContext <
                        DynamicDataService::InstantiationContext
                class Child < BasicObject
                    def initialize(context, child)
                        @context = context
                        @child = child
                    end

                    def require_dynamic_service(dynamic_service_name,
                        as: nil, **dyn_options)
                        @child = @context.specialized_child(@child)
                        srv = @child.model.require_dynamic_service(
                            dynamic_service_name, as: as, **dyn_options
                        )
                        srv.attach(@child)
                    end

                    def respond_to_missing?(m, include_private)
                        if m.to_s =~ /_port$/
                            @child.respond_to?(m)
                        else super
                        end
                    end

                    def method_missing(m, *args)
                        if m.to_s =~ /_port$/
                            @child.public_send(m, *args)
                        else
                            super
                        end
                    end
                end

                def initialize(component_model, name, dynamic_service, **options)
                    @specialized = Set.new
                    super
                end

                def specialized_child(child)
                    child_name = child.child_name
                    unless @specialized.include?(child_name)
                        @specialized << child_name
                        component_model.overload child_name, child.specialize
                    end
                    component_model.find_child(child_name)
                end

                def export(port, **options)
                    component_model.export(port, **options)
                end

                def add(*args, **options, &block)
                    child = component_model.add(*args, **options, &block)
                    Child.new(self, child)
                end

                def overload(*args, **options, &block)
                    child = component_model.overload(*args, **options, &block)
                    Child.new(self, child)
                end

                def respond_to_missing?(m, include_private)
                    if m =~ /_child$/
                        component_model.respond_to?(m)
                    else super
                    end
                end

                def method_missing(m, *args, &block)
                    if m =~ /_child$/
                        Child.new(self, component_model.public_send(m, *args, &block))
                    else
                        super
                    end
                end
            end

            # @api private
            #
            # (see Component#create_dynamic_instantiation_context)
            def create_dynamic_instantiation_context(name, dynamic_service, **options)
                DynamicServiceInstantiationContext.new(
                    self, name, dynamic_service, **options
                )
            end

            # Explicitly create the given connections between children of this
            # composition.
            #
            # Example:
            #   composition 'Test' do
            #       source = add 'Source'
            #       sink   = add 'Sink'
            #       connect source.output => sink.input, :type => :buffer
            #   end
            #
            # Explicit connections always have precedence on automatic
            # connections. See #autoconnect for automatic connection handling
            def connect(mappings)
                options = {}
                mappings.delete_if do |a, b|
                    options[a] = b if a.respond_to?(:to_str)
                end
                unless options.empty?
                    options = Kernel.validate_options(
                        options, Orocos::Port::CONNECTION_POLICY_OPTIONS
                    )
                end
                mappings.each do |out_p, in_p|
                    out_p.connect_to in_p
                end
            end

            # (see SpecializationManager#add_specialization_constraint)
            def add_specialization_constraint(explicit = nil, &block)
                specializations.add_specialization_constraint(explicit, &block)
            end

            # Returns the set of constraints that exist for the given child.
            # I.e. the set of types that, at instanciation time, the chosen
            # child must provide.
            #
            # See #constrain
            def constraints_for(child_name)
                result = Set.new
                each_child_constraint(child_name, false) do |constraint_set|
                    result |= constraint_set.to_set
                end
                result
            end

            def children_names
                each_child.map { |name, _| name }
            end

            # The list of names that will be used by this model as keys in a
            # DependencyInjection object,
            #
            # For compositions, this is the list of children names
            def dependency_injection_names
                children_names
            end

            def find_child_model_and_task(child_name, context)
                Models.debug do
                    Models.debug "selecting #{child_name}:"
                    Models.log_nest(2) do
                        Models.debug "on the basis of"
                        Models.log_nest(2) do
                            Models.log_pp(:debug, context)
                        end
                    end
                    break
                end
                child_requirements = find_child(child_name)
                selected_child, used_keys =
                    context.instance_selection_for(child_name, child_requirements)
                Models.debug do
                    Models.debug "selected"
                    Models.log_nest(2) do
                        Models.log_pp(:debug, selected_child)
                    end
                    break
                end
                explicit = context.has_selection_for?(child_name)
                [selected_child, explicit, used_keys]
            end

            # Given a dependency injection context, it computes the models and
            # task instances for each of the composition's children
            #
            # @return [(Hash<String,InstanceSelection>,
            #           Hash<String,InstanceSelection>,
            #           Hash<String,Set>)] the resolved selections.
            #   The first hash is the set of explicitly selected children (i.e.
            #   selected by name) and the second is all the selections. The last
            #   returned value is the set keys in context that have been used to
            #   perform the resolution
            def find_children_models_and_tasks(context)
                explicit = {}
                result   = {}
                used_keys = {}
                each_child do |child_name, _child_requirements|
                    result[child_name], child_is_explicit, used_keys[child_name] =
                        find_child_model_and_task(child_name, context)

                    explicit[child_name] = result[child_name] if child_is_explicit
                end

                [explicit, result, used_keys]
            end

            # Returns the set of specializations that match the given dependency
            # injection context
            #
            # @param [DependencyInjection] context the dependency injection
            #   object that is used to determine the selected model
            # @return [Model<Composition>]
            def narrow(context, **options)
                explicit_selections, selected_models, =
                    find_children_models_and_tasks(context)
                find_applicable_specialization_from_selection(
                    explicit_selections, selected_models, **options
                )
            end

            # Returns this composition associated with dependency injection
            # information
            #
            # For instance,
            #
            #   CorridorServoing.
            #       use(Odometry.use(XsensImu::Task))
            #
            # (see InstanceRequirements#use)
            def use(*spec)
                InstanceRequirements.new([self]).use(*spec)
            end

            # Returns this composition associated with specialization
            # disambiguation information
            #
            # For instance,
            #
            #   CorridorServoing.
            #       prefer_specializations('child' => XsensImu::Task)
            #
            # (see InstanceRequirements#prefer_specializations)
            def prefer_specializations(*spec)
                InstanceRequirements.new([self]).prefer_specializations(*spec)
            end

            # Instanciates a task for the required child
            def instanciate_child(plan, context, _self_task, child_name, selected_child)
                Models.debug "instanciating child #{child_name}"
                Models.debug do
                    Models.log_nest 2
                    break
                end

                child_arguments = selected_child.selected.arguments
                child_arguments.each_key do |key|
                    value = child_arguments[key]
                    if value.respond_to?(:resolve_child)
                        child_arguments[key] = value.resolve_child(self)
                    end
                end

                selected_child.instanciate(plan, context, task_arguments: child_arguments)
            ensure
                Models.debug do
                    Models.log_nest(-2)
                    break
                end
            end

            def instanciate_connections(self_task, selected_children, children_tasks)
                # The set of connections we must create on our children. This is
                # self.connections on which we will apply port mappings for the
                # instanciated children
                each_explicit_connection do |(out_name, in_name), conn|
                    out_task = children_tasks[out_name]
                    in_task = children_tasks[in_name]

                    if out_task && in_task
                        child_out    = selected_children[out_name]
                        child_in     = selected_children[in_name]
                        mappings_out = child_out.port_mappings
                        mappings_in  = child_in.port_mappings

                        mapped = {}
                        conn.each do |(port_out, port_in), policy|
                            mapped_port_out = mappings_out[port_out] || port_out
                            mapped_port_in  = mappings_in[port_in] || port_in
                            mapped[[mapped_port_out, mapped_port_in]] = policy
                        end

                        out_task.connect_ports(in_task, mapped)
                    end
                end

                each_exported_input do |export_name, port|
                    child_name = port.component_model.child_name
                    if (child_task = children_tasks[child_name])
                        child = selected_children[child_name]
                        self_task.forward_input_ports(
                            child_task,
                            [export_name, child.port_mappings[port.name]] => {}
                        )
                    end
                end
                each_exported_output do |export_name, port|
                    child_name = port.component_model.child_name
                    if (child_task = children_tasks[child_name])
                        child = selected_children[child_name]
                        child_task.forward_output_ports(
                            self_task,
                            [child.port_mappings[port.name], export_name] => {}
                        )
                    end
                end
            end

            def find_applicable_specialization_from_selection(
                explicit_selections, selections, **options
            )
                specialized_model = specializations.matching_specialized_model(
                    explicit_selections, **options
                )
                return specialized_model if specialized_model != self

                specializations.matching_specialized_model(selections, **options)
            end

            # Resolves references to other children in a child's use flags
            #
            # This updates the selected_child requirements to replace
            # CompositionChild object by the actual task instance.
            #
            # @param [Composition] self_task the task that represents the
            #   composition itself
            # @param [InstanceSelection] selected_child the requirements that
            #   are meant to be updated
            #
            # @return [Boolean] if all references could be updated, false
            # otherwise
            def try_resolve_child_references_in_use_flags(self_task, selected_child)
                # Check if selected_child points to another child of
                # self, and if it is the case, make sure it is available
                selected_child.map_use_selections! do |sel|
                    if sel.kind_of?(CompositionChild)
                        task = sel.try_resolve_and_bind_child_recursive(self_task)
                        return unless task # rubocop:disable Lint/NonLocalExitFromIterator

                        task
                    else sel
                    end
                end
                true
            end

            # Extracts the selections for grandchildren out of a selection for
            # this
            #
            # It matches the child_name.granchild_name pattern and returns a
            # hash with the matching selections
            #
            # @param [String] child_name the child name
            # @param [Hash] selections the selection hash
            def extract_grandchild_selections_by_child_name(child_name, selections)
                child_user_selection = {}
                match = /^#{child_name}\.(.*)$/
                selections.each do |name, sel|
                    if name.respond_to?(:to_str) && (m = match.match(name.to_str))
                        child_user_selection[m[1]] = sel
                    end
                end
                child_user_selection
            end

            # Computes the options for depends_on needed to add child_task as
            # the child_name's composition child
            #
            # @param [String] child_name
            # @param [Component] child_task
            # @return [Hash]
            def compute_child_dependency_options(child_name, child_task)
                child_m = find_child(child_name)
                dependent_models = child_m.each_required_model.to_a
                dependent_arguments = dependent_models.inject({}) do |result, m|
                    result.merge(m.meaningful_arguments(child_task.arguments))
                end
                if child_task.has_argument?(:conf)
                    dependent_arguments[:conf] = child_task.arguments[:conf]
                end

                dependency_options =
                    Roby::TaskStructure::Dependency
                    .validate_options(child_m.dependency_options)
                default_options =
                    Roby::TaskStructure::Dependency
                    .validate_options(model: [dependent_models, dependent_arguments],
                                      roles: [child_name].to_set)
                dependency_options =
                    Roby::TaskStructure::Dependency
                    .merge_dependency_options(dependency_options, default_options)
                unless dependency_options[:success]
                    dependency_options = { success: [], failure: [:stop] }
                                         .merge(dependency_options)
                end
                dependency_options
            end

            # Creates the required task and children for this composition model.
            #
            # It selects the relevant specialization and instantiates it instead
            # of +self+ when relevant.
            #
            # @param [Roby::Plan] the plan in which the composition should be
            #   instantiated
            # @param [DependencyInjectionContext] context the dependency
            #   injection used to select the actual models for the children (and
            #   therefore the specializations as well). The last element in this
            #   DIContext stack is interpreted as DI setup only for the
            #   composition (not for the instantiation of its children).
            # @option arguments [Boolean] specialize (true) if true, a suitable
            #   specialization will be selected. Otherwise, the specialization
            #   resolution is bypassed.
            # @option arguments [Hash] task_arguments the set of arguments that
            #   should be passed to the composition task instance
            def instanciate(plan, context = DependencyInjectionContext.new,
                task_arguments: {},
                specialize: true,
                specialization_hints: [])

                Models.debug do
                    Models.debug "instanciating #{short_name} with"
                    Models.log_nest(2)
                    Models.log_pp(:debug, context)
                    break
                end

                # Find what we should use for our children. +explicit_selection+
                # is the set of children for which a selection existed and
                # +selected_models+ all the models we should use
                explicit_selections, selected_models, used_keys =
                    find_children_models_and_tasks(context.current_state)

                if specialize
                    specialized_model = find_applicable_specialization_from_selection(
                        explicit_selections,
                        selected_models,
                        specialization_hints: specialization_hints
                    )
                    if specialized_model != self
                        return specialized_model.instanciate(
                            plan, context,
                            task_arguments: task_arguments,
                            specialize: true,
                            specialization_hints: specialization_hints
                        )
                    end
                end

                # First of all, add the task for +self+
                plan.add(self_task = new(**task_arguments))
                conf = if self_task.has_argument?(:conf)
                           self_task.conf(self_task.arguments[:conf])
                       else {}
                       end

                # This is the part of the context that is directly associated
                # with the composition. We use it later to extract by-name
                # selections for the children of the form
                # child_name.child_of_child_name
                composition_use_flags = context.top

                # Finally, instanciate the missing tasks and add them to our
                # children
                children_tasks = {}
                remaining_children_models = selected_models.dup
                until remaining_children_models.empty?
                    current_size = remaining_children_models.size
                    remaining_children_models.delete_if do |child_name, selected_child|
                        selected_child = selected_child.dup

                        resolved_selected_child = selected_child
                        if selected_child.selected.fullfills?(Syskit::Composition)
                            resolved_selected_child = selected_child.dup

                            has_unresolved_reference_to_sibling =
                                !try_resolve_child_references_in_use_flags(
                                    self_task, resolved_selected_child.selected
                                )
                            next if has_unresolved_reference_to_sibling

                            child_user_selection =
                                extract_grandchild_selections_by_child_name(
                                    child_name, composition_use_flags.added_info.explicit
                                )
                            resolved_selected_child.selected.use(child_user_selection)
                        end

                        child_task = context.save do
                            context.push_mask(used_keys[child_name])
                            instanciate_child(plan, context, self_task,
                                              child_name, resolved_selected_child)
                        end
                        child_task = child_task.to_task

                        if (child_conf = conf[child_name])
                            child_task.arguments[:conf] ||= child_conf
                        end

                        children_tasks[child_name] = child_task

                        dependency_options = compute_child_dependency_options(
                            child_name, child_task
                        )
                        Models.info do
                            Models.info "adding dependency #{self_task}"
                            Models.info "    => #{child_task}"
                            Models.info "   options; #{dependency_options}"
                            break
                        end

                        self_task.depends_on(child_task, dependency_options)
                        self_task.child_selection[child_name] = selected_child
                        if (main = main_task) && (main.child_name == child_name)
                            child_task.each_event do |ev|
                                should_forward = !ev.terminal? && ev.symbol != :start &&
                                                 self_task.has_event?(ev.symbol)

                                if should_forward
                                    child_task.event(ev.symbol)
                                              .forward_to self_task.event(ev.symbol)
                                end
                            end
                            child_task.success_event.forward_to self_task.success_event
                        end
                        true # it has been processed, delete
                    end
                    if remaining_children_models.size == current_size
                        remaining_children_names = remaining_children_models
                                                   .map(&:first).sort.join(", ")
                        raise InternalError, "cannot resolve children "\
                                             "#{remaining_children_names}"
                    end
                end

                instanciate_connections(self_task, selected_models, children_tasks)
                self_task
            ensure
                Models.debug do
                    Models.log_nest(-2)
                    break
                end
            end

            def to_dot(io)
                id = object_id.abs

                connections.each do |(source, sink), mappings|
                    mappings.each do |(source_port, sink_port), _policy|
                        io << "C#{id}#{source}:#{source_port} -> "\
                              "C#{id}#{sink}:#{sink_port};"
                    end
                end

                unless is_specialization?
                    specializations = each_specialization.to_a
                    specializations.each do |_spec, specialized_model|
                        specialized_model.to_dot(io)

                        specialized_model.parent_models.each do |parent_compositions|
                            parent_id = parent_compositions.object_id
                            specialized_id = specialized_model.object_id
                            io << "C#{parent_id} -> C#{specialized_id} "\
                                  "[ltail=cluster_#{parent_id} "\
                                  "lhead=cluster_#{specialized_id} weight=2];"
                        end
                    end
                end

                io << "subgraph cluster_#{id} {"
                io << "  fontsize=18;"
                io << "  C#{id} [style=invisible];"

                if !exported_inputs.empty? || !exported_outputs.empty?
                    inputs = exported_inputs.keys
                    outputs = exported_outputs.keys
                    label = Graphviz.dot_iolabel("Composition Interface", inputs, outputs)
                    io << "  Cinterface#{id} [label=\"#{label}\",color=blue,fontsize=15];"

                    exported_outputs.each do |exported_name, port|
                        io << "C#{id}#{port.component_model.child_name}:"\
                              "#{port.port.name} -> "\
                              "Cinterface#{id}:#{exported_name} "\
                              "[style=dashed];"
                    end
                    exported_inputs.each do |exported_name, port|
                        io << "Cinterface#{id}:#{exported_name} -> "\
                              "C#{id}#{port.component_model.child_name}:"\
                              "#{port.port.name} "\
                              "[style=dashed];"
                    end
                end
                label = [short_name.dup]
                provides = each_data_service.map do |name, type|
                    "#{name}:#{type.model.short_name}"
                end
                label << "Abstract" if abstract?
                unless provides.empty?
                    label << "Provides:"
                    label.concat(provides)
                end
                io << "  label=\"#{label.join('\\n')}\";"
                # io << "  label=\"#{model.name}\";"
                # io << "  C#{id} [style=invisible];"
                each_child do |child_name, child_definition|
                    child_model = child_definition.each_required_model

                    task_label = child_model.map(&:short_name).join(",")
                    task_label = "#{child_name}[#{task_label}]"
                    inputs = child_model.map { |m| m.each_input_port.map(&:name) }
                                        .inject(&:concat).to_a
                    outputs = child_model.map { |m| m.each_output_port.map(&:name) }
                                         .inject(&:concat).to_a
                    label = Graphviz.dot_iolabel(task_label, inputs, outputs)

                    if child_model.any? { |m| !m.fullfills?(Component) || m.abstract? }
                        color = ', color="red"'
                    end
                    io << "  C#{id}#{child_name} "\
                          "[label=\"#{label}\"#{color},fontsize=15];"
                end
                io << "}"
            end

            # Create a new submodel of this composition model that will be used
            # to represent a specialization
            def new_specialized_submodel(**options, &block)
                submodel = new_submodel(**options.merge(register_specializations: false),
                                        &block)
                submodel.extend Models::CompositionSpecialization::Extension
                submodel
            end

            # Overloaded to set the model documentation
            def inherited(submodel)
                super
                submodel.doc MetaRuby::DSLs.parse_documentation_block(/.*/, /^inherited/)
            end

            # Create a new submodel of this composition model
            def setup_submodel(submodel, register_specializations: true,
                **submodel_options, &block)
                super(submodel, **submodel_options, &block)

                if register_specializations
                    specializations.each_specialization do |spec|
                        next if applied_specializations.include?(spec)

                        spec.specialization_blocks.each do |spec_block|
                            specialized_children =
                                spec.specialized_children
                                    .transform_keys do |child_name|
                                        submodel.find_child(child_name)
                                    end
                            submodel.specialize(specialized_children, &spec_block)
                        end
                    end
                end
                submodel.applied_specializations |= applied_specializations.to_set
                submodel
            end

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m, "_child" => :find_child
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args, "_child" => :find_child
                ) || super
            end

            # Helper method for {#promote_exported_output} and
            # {#promote_exported_input}
            def promote_exported_port(_export_name, port)
                if (new_child = children[port.component_model.child_name])
                    if (new_port_name = new_child.port_mappings[port.name])
                        find_child(port.component_model.child_name)
                            .find_port(new_port_name).dup
                    else
                        port
                    end
                else
                    port
                end
            end

            # Method that maps exports from this composition's parent models to
            # this composition's own interface
            #
            # It is called as needed when calling {#each_exported_output}
            def promote_exported_output(export_name, port)
                exported_outputs[export_name] = promote_exported_port(export_name, port)
            end

            # Outputs exported from components in this composition to this
            # composition's interface
            #
            # @key_name exported_port_name
            # @return [Hash<String,Port>]
            inherited_attribute(:exported_output, :exported_outputs, map: true) do
                {}
            end

            # Method that maps exports from this composition's parent models to
            # this composition's own interface
            #
            # It is called as needed when calling {#each_exported_input}
            def promote_exported_input(export_name, port)
                exported_inputs[export_name] = promote_exported_port(export_name, port)
            end

            # Inputs exported from components in this composition to this
            # composition's interface
            #
            # @key_name exported_port_name
            # @return [Hash<String,Port>]
            inherited_attribute(:exported_input, :exported_inputs, map: true) do
                {}
            end

            # Configurations defined on this composition model
            #
            # @key_name conf_name
            # @return [Hash<String,Hash<String,String>>] the mapping from a
            #   composition configuration name to the corresponding
            #   configurations that should be applied to its children
            # @see {#conf}
            inherited_attribute(:configuration, :configurations, map: true) do
                {}
            end

            # Declares a composition configuration
            #
            # Composition configurations are named selections of configurations.
            #
            # For instance, if
            #
            #   conf 'narrow',
            #       'monitoring' => ['default', 'narrow_window'],
            #       'sonar' => ['default', 'narrow_window']
            #
            # is declared, and the composition is instanciated with
            #
            #   Cmp::SonarMonitoring.use_conf('narrow')
            #
            # Then the composition children called 'monitoring' and 'sonar' will
            # be both instanciated with ['default', 'narrow_window']
            def conf(name, mappings = {})
                mappings = mappings.transform_keys do |child|
                    if child.respond_to?(:to_str)
                        conf = mappings[child]
                        Roby.warn_deprecated "providing the child as string in #conf "\
                            "is deprecated, use the _child accessors "\
                            "instead (here #{child}_child => [#{conf.join(', ')}])"
                        child
                    else
                        child.child_name
                    end
                end
                configurations[name] = mappings
            end

            # Merge two models, making sure that specializations are properly
            # applied on the result
            def merge(other_model)
                needed_specializations = applied_specializations
                if other_model.respond_to?(:root_model)
                    needed_specializations |= other_model.applied_specializations
                    other_model = other_model.root_model
                end

                if needed_specializations.empty?
                    super(other_model)
                else
                    base_model = root_model.merge(other_model)
                    # If base_model is a placeholder model, we apply the
                    # specialization on the proper composition model and then
                    # re-proxy it
                    services = []
                    if base_model.placeholder?
                        services   = base_model.proxied_data_service_models
                        base_model = base_model.proxied_component_model
                    end

                    composite_spec = CompositionSpecialization
                                     .merge(*needed_specializations)
                    result = base_model.specializations.specialized_model(
                        composite_spec, needed_specializations
                    )
                    Placeholder.for(services.to_a, component_model: result)
                end
            end

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def fullfills?(models)
                models = [models] unless models.respond_to?(:map)
                models = models.map do |other_model|
                    if other_model.respond_to?(:applied_specializations)
                        missing_specializations =
                            other_model.applied_specializations - applied_specializations
                        return false unless missing_specializations.empty?

                        other_model.root_model
                    else
                        other_model
                    end
                end
                super(models)
            end
        end
    end
end
