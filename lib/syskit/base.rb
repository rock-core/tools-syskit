require 'logger'
require 'utilrb/logger'
module Orocos
    # Roby is a plan management component, i.e. a supervision framework that is
    # based on the concept of plans.
    #
    # See http://doudou.github.com/roby for more information.
    #
    # This module includes both the Roby bindings, i.e. what allows to represent
    # Orocos task contexts and deployment processes in Roby, and a model-based
    # system configuration environment.
    module RobyPlugin
        extend Logger::Forward
        extend Logger::Hierarchy

        class InternalError < RuntimeError; end
        class ConfigError < RuntimeError; end
        class SpecError < RuntimeError; end
        class Ambiguous < SpecError; end

        # Returns an array of modules. It is used as the search path for DSL
        # parsing.
        #
        # I.e. when someone uses a ClassName in a DSL, this constant will be
        # searched following the order of modules returned by this method.
        def self.constant_search_path
            [Orocos::RobyPlugin::Interfaces, Orocos::RobyPlugin::DeviceDrivers, Orocos::RobyPlugin::Compositions, Orocos::RobyPlugin]
        end

        # Generic module included in all classes that are used as models.
        #
        # The Roby plugin uses, as Roby does, Ruby classes as model objects. To
        # ease code reading, the model-level functionality (i.e. singleton
        # classes) are stored in separate modules whose name finishes with Model
        #
        # For instance, the singleton methods of Component are defined on
        # ComponentModel, Composition on CompositionModel and so on.
        module Model
            # All models are defined in the context of a SystemModel instance.
            # This is this instance
            attr_accessor :system

            def to_s # :nodoc:
                supermodels = ancestors.map(&:name)
                i = supermodels.index("Orocos::RobyPlugin::Component")
                supermodels = supermodels[0, i]
                supermodels = supermodels.map do |name|
                    name.gsub(/Orocos::RobyPlugin::(.*)/, "\\1") if name
                end
                "#<#{supermodels.join(" < ")}>"
            end

            # Creates a new class that is a submodel of this model
            def new_submodel
                klass = Class.new(self)
                klass.system = system
                klass
            end

            # Helper for #instance calls on components
            def self.filter_instanciation_arguments(options)
                arguments, task_arguments = Kernel.filter_options(
                    options, :selection => Hash.new, :as => nil)
            end

        end

        # For 1.8 compatibility
        if !defined?(BasicObject)
            BasicObject = Object
        end

        # Value returned by ComponentModel#as(model). It is used only in the
        # context of model instanciation.
        #
        # It is used to represent that a given model should be narrowed down to
        # a given specific model, and is used during composition instanciation
        # to limit the search scope.
        #
        # For instance, if a task model is defined with
        #
        #   class OrocosTask
        #       provides Service
        #       provides Service1
        #   end
        #
        # then
        #   
        #   add MyComposition, 
        #       "task" => OrocosTask
        #
        # will consider both data services for specialization purposes, whereas
        #
        #   add MyComposition, 
        #       "task" => OrocosTask.as(Service)
        #
        # will only consider specializations that apply on Service instances
        # (i.e. ignore Service1)
        class FacetedModelSelection < BasicObject
            # The underlying model
            attr_reader :model
            # The model that has been selected
            attr_reader :selected_facet

            def respond_to?(name) # :nodoc:
                if name == :selected_facet
                    true
                else
                    super
                end
            end

            def initialize(model, facet)
                @model = model
                @selected_facet = facet
            end

            def to_s
                "#{model}.as(#{selected_facet})"
            end

            def method_missing(*args, &block) # :nodoc:
                model.send(*args, &block)
            end
        end

        # Definition of model-level methods for the Component models. See the
        # documentation of Model for an explanation of this.
        module ComponentModel
            ##
            # :method: each_main_data_source { |source_name| ... }
            #
            # Enumerates the name of all the main data sources that are provided
            # by this component model. Unlike #main_data_sources, it enumerates
            # both the sources added at this level of the model hierarchy and
            # the ones that are provided by the model's parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ## :attr_reader:main_data_sources
            #
            # The names of the main data sources that are provided by this
            # particular component model. This only includes new sources that
            # have been added at this level of the component hierarchy, not the
            # ones that have already been added to the model parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ##
            # :method: each_data_source { |name, source| ... }
            #
            # Enumerates all the data sources that are provided by this
            # component model, as pairs of source name and DataSource instances.
            # Unlike #data_sources, it enumerates both the sources added at
            # this level of the model hierarchy and the ones that are provided
            # by the model's parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ##
            # :method: find_data_source(name)
            #
            # Returns the DataSource instance that has the given name, or nil if
            # there is none.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            ## :attr_reader:data_sources
            #
            # The data sources that are provided by this particular component
            # model, as a hash mapping the source name to the corresponding
            # DataSource instance. This only includes new sources that have been
            # added at this level of the component hierarchy, not the ones that
            # have already been added to the model parents.
            #
            # See also #provides
            #--
            # This is defined on Component using inherited_enumerable

            # During instanciation, the data services that this component
            # provides are used to specialize the compositions and/or for data
            # source selection.
            #
            # It is sometimes beneficial to narrow the possible selections,
            # because one wants some specializations to be explicitely selected.
            # This is what this method does.
            #
            # For instance, if a task model is defined with
            #
            #   class OrocosTask
            #       provides Service
            #       provides Service1
            #   end
            #
            # then
            #   
            #   add MyComposition, 
            #       "task" => OrocosTask
            #
            # will consider both data services for specialization purposes, whereas
            #
            #   add MyComposition, 
            #       "task" => OrocosTask.as(Service)
            #
            # will only consider specializations that apply on Service instances
            # (i.e. ignore Service1)
            def as(model)
                FacetedModelSelection.new(self, model)
            end

            # Returns the port object that maps to the given name, or nil if it
            # does not exist.
            def port(name)
                name = name.to_str
                output_port(name) || input_port(name)
            end

            # Returns the output port with the given name, or nil if it does not
            # exist.
            def output_port(name)
                name = name.to_str
                each_output.find { |p| p.name == name }
            end

            # Returns the input port with the given name, or nil if it does not
            # exist.
            def input_port(name)
                name = name.to_str
                each_input.find { |p| p.name == name }
            end

            # Enumerates this component's output ports
            def each_output(&block)
                orogen_spec.each_output_port(&block)
            end

            # Enumerates this component's input ports
            def each_input(&block)
                orogen_spec.each_input_port(&block)
            end

            # Enumerates all of this component's ports
            def each_port(&block)
                if block_given?
                    each_input(&block)
                    each_output(&block)
                    self
                else
                    enum_for(:each_port)
                end
            end

            # True if +name+ could be a dynamic output port name.
            #
            # Dynamic output ports are declared on the task models using the
            # #dynamic_output_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_output_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic output port declarations using this predicate.
            def dynamic_output_port?(name)
                orogen_spec.dynamic_output_port?(name)
            end

            # True if +name+ could be a dynamic input port name.
            #
            # Dynamic input ports are declared on the task models using the
            # #dynamic_input_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_input_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic input port declarations using this predicate.
            def dynamic_input_port?(name)
                orogen_spec.dynamic_input_port?(name)
            end

            # Generic instanciation of a component. 
            #
            # It creates a new task from the component model using
            # Component.new, adds it to the engine's plan and returns it.
            def instanciate(engine, arguments = Hash.new)
                _, task_arguments = Model.filter_instanciation_arguments(arguments)
                engine.plan.add(task = new(task_arguments))
                task.robot = engine.robot
                task
            end
        end

        # Base class for models that represent components (TaskContext,
        # Composition)
        #
        # The model-level methods (a.k.a. singleton methods) are defined on
        # ComponentModel). See the documentation of Model for an explanation of
        # this.
        #
        # Components may be data source providers. Two types of data sources exist:
        # * main sources are root data services that can be provided
        # independently
        # * slave sources are data services that depend on a main one. For
        # instance, an ImageProvider source of a StereoCamera task would be
        # slave of the main PointCloudProvider source.
        #
        # Data services are referred to by name. In the case of a main service,
        # its name is the name used during the declaration. In the case of slave
        # services, it is main_data_service_name.slave_name. I.e. the name of
        # the slave service depends on the selected 
        class Component < ::Roby::Task
            extend ComponentModel

            # The Robot instance we are running on
            attr_accessor :robot

            def create_fresh_copy
                new_task = super
                new_task.robot = robot
                new_task
            end

            # This is documented on ComponentModel
            inherited_enumerable(:main_data_source, :main_data_sources) { Set.new }
            # This is documented on ComponentModel
            inherited_enumerable(:data_source, :data_sources, :map => true) { Hash.new }

            attribute(:instanciated_dynamic_outputs) { Hash.new }
            attribute(:instanciated_dynamic_inputs) { Hash.new }

            # Returns the output port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def output_port_model(name)
                if port_model = model.orogen_spec.each_output_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_outputs[name]
                end
            end

            # Returns the input port model for the given name, or nil if the
            # model has no port named like this.
            #
            # It may return an instanciated dynamic port
            def input_port_model(name)
                if port_model = model.orogen_spec.each_input_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_inputs[name]
                end
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_input(name, type = nil)
                if port = instanciated_dynamic_inputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_input_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_inputs[name] = port
            end

            # Instanciate a dynamic port, i.e. request a dynamic port to be
            # available at runtime on this component instance.
            def instanciate_dynamic_output(name, type = nil)
                if port = instanciated_dynamic_outputs[name]
                    port
                end

                candidates = model.orogen_spec.find_dynamic_output_ports(name, type)
                if candidates.size > 1
                    raise Ambiguous, "I don't know what to use for dynamic port instanciation"
                end

                port = candidates.first.instanciate(name)
                instanciated_dynamic_outputs[name] = port
            end

            DATA_SOURCE_ARGUMENTS = { :as => nil, :slave_of => nil, :main => nil }

            def self.provides(*args)
                data_source(*args)
            end

            def self.data_source(model, arguments = Hash.new)
                source_arguments, arguments = Kernel.filter_options arguments,
                    DATA_SOURCE_ARGUMENTS

                if model.respond_to?(:to_str)
                    begin
                        model = Orocos::RobyPlugin::Interfaces.const_get model.to_str.camelcase(true)
                    rescue NameError
                        raise ArgumentError, "there is no data source type #{model}"
                    end
                end

                if !(model < DataSource)
                    raise ArgumentError, "#{model} is not a data source model"
                end

                # If true, the source will be marked as 'main', i.e. the port
                # mapping between the source and the component will match plain
                # port names (without the source name prefixed/postfixed)
                main_data_source = if source_arguments.has_key?(:main)
                                       source_arguments[:main]
                                   else !source_arguments[:as]
                                   end

                # In case it *is* a main source, check if our parent models
                # already have a source which we could specialize. In that case,
                # reuse their name
                if !source_arguments[:as]
                    if respond_to?(:each_main_data_source)
                        candidates = each_main_data_source.find_all do |source|
                            !data_sources[source] &&
                                model <= data_source_type(source)
                        end

                        if candidates.size > 1
                            candidates = candidates.map { |name, _| name }
                            raise Ambiguous, "this definition could overload the following sources: #{candidates.join(", ")}. Select one with the :as option"
                        end
                        source_arguments[:as] = candidates.first
                    end
                end

                # Get the source name and the source model
                name = (source_arguments[:as] || model.name.gsub(/^.+::/, '').snakecase).to_str
                if data_sources[name]
                    raise ArgumentError, "there is already a source named '#{name}' defined on '#{name}'"
                end

                # Verify that the component interface matches the data source
                # interface
                model.verify_implemented_by(self, main_data_source, name)

                # If a source with the same name exists, verify that the user is
                # trying to specialize it
                if has_data_source?(name)
                    parent_type = data_source_type(name)
                    if !(model <= parent_type)
                        raise SpecError, "#{self} has a data source named #{name} of type #{parent_type}, which is not a parent type of #{model}"
                    end
                end

                include model
                arguments.each do |key, value|
                    send("#{key}=", value)
                end

                if parent_source = source_arguments[:slave_of]
                    if !has_data_source?(parent_source.to_str)
                        raise SpecError, "parent source #{parent_source} is not registered on #{self}"
                    end

                    data_sources["#{parent_source}.#{name}"] = model
                else
                    data_sources[name] = model
                    if main_data_source
                        main_data_sources << name
                    end
                end
                return name, model
            end


            # Return the selected name for the given data source, or nil if none
            # is selected yet
            def selected_data_source(data_source_name)
                root_source, child_source = model.break_data_source_name(data_source_name)
                if child_source
                    # Get the root name
                    if selected_source = selected_data_source(root_source)
                        return "#{selected_source}.#{child_source}"
                    end
                else
                    arguments["#{root_source}_name"]
                end
            end

            def data_source_type(source_name)
                source_name = source_name.to_str
                root_source_name = source_name.gsub /\..*$/, ''
                root_source = model.each_root_data_source.find do |name, source|
                    arguments[:"#{name}_name"] == root_source_name
                end

                if !root_source
                    raise ArgumentError, "there is no source named #{root_source_name}"
                end
                if root_source_name == source_name
                    return root_source.last
                end

                subname = source_name.gsub /^#{root_source_name}\./, ''

                model = self.model.data_source_type("#{root_source.first}.#{subname}")
                if !model
                    raise ArgumentError, "#{subname} is not a slave source of #{root_source_name} (#{root_source.first}) in #{self.model.name}"
                end
                model
            end

            def check_is_setup
                true
            end

            def is_setup?
                @is_setup ||= check_is_setup
            end


            def executable?(with_setup = true)
                if !super()
                    return false
                end

                if with_setup
                    if !is_setup?
                        return false
                    end

                    if pending?
                        return Roby.app.orocos_engine.all_inputs_connected?(self, false)
                    end
                end
                true
            end

            def user_required_model
                models = model.ancestors
                models.shift if abstract?
                klass  = models.find { |t| t.kind_of?(Class) }
                models = models.find_all { |t| t.kind_of?(Roby::TaskModelTag) }
                models.push(klass) if klass
                models
            end

            def can_merge?(target_task)
                return false if !super

                # The orocos bindings are a special case: if +target_task+ is
                # abstract, it means that it is a proxy task for data
                # source/device drivers model
                #
                # In that particular case, the only thing the automatic merging
                # can do is replace +target_task+ iff +self+ fullfills all tags
                # that target_task has (without considering target_task itself).
                models = user_required_model
                if !fullfills?(models)
                    return false
                end

                # Now check that the connections are compatible
                #
                # We search for connections that use the same input port, and
                # verify that they are coming from the same output
                self_inputs = Hash.new
                each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if self_inputs.has_key?(sink_port)
                        raise InternalError, "multiple connections to the same input: #{self}:#{sink_port} is connected from #{source_task}:#{source_port} and #{self_inputs[sink_port]}"
                    end
                    self_inputs[sink_port] = [source_task, source_port, policy]
                end
                target_task.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                    if conn = self_inputs[sink_port]
                        same_source = (conn[0] == source_task && conn[1] == source_port)
                        if !same_source
                            return false
                        elsif !policy.empty? && (RobyPlugin.update_connection_policy(conn[2], policy) != policy)
                            return false
                        end
                    end
                end

                true
            end

            def merge(merged_task)
                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each do |key, value|
                    arguments[key] ||= value if !arguments.has_key?(key)
                end

                # Instanciate missing dynamic ports
                self.instanciated_dynamic_outputs =
                    merged_task.instanciated_dynamic_outputs.merge(instanciated_dynamic_outputs)
                self.instanciated_dynamic_inputs =
                    merged_task.instanciated_dynamic_inputs.merge(instanciated_dynamic_inputs)

                # Finally, remove +merged_task+ from the data flow graph and use
                # #replace_task to replace it completely
                plan.replace_task(merged_task, self)
                nil
            end

            def self.method_missing(name, *args)
                if args.empty? && (port = self.port(name))
                    port
                else
                    super
                end
            end

            # Map the given port name of +source_type+ into the port that
            # is owned by +source_name+ on +target_type+
            #
            # +source_type+ has to be a plain data source (i.e. not a task)
            #
            # Raises ArgumentError if no mapping is found
            def self.source_port(source_type, source_name, port_name)
                source_port = source_type.port(port_name)
                if main_data_source?(source_name)
                    if port(port_name)
                        return port_name
                    else
                        raise ArgumentError, "expected #{self} to have a port named #{source_name}"
                    end
                else
                    path    = source_name.split '.'
                    targets = []
                    while !path.empty?
                        target_name = "#{path.join('_')}_#{port_name}".camelcase
                        if port(target_name)
                            return target_name
                        end
                        targets << target_name

                        target_name = "#{port_name}_#{path.join('_')}".camelcase
                        if port(target_name)
                            return target_name
                        end
                        targets << target_name
                        path.shift
                    end
                    raise ArgumentError, "expected #{self} to have a port of type #{source_port.type_name} named as one of the following possibilities: #{targets.join(", ")}"
                end
            end
        end

        class ConnectionGraph < BGL::Graph
            def add_connections(source_task, sink_task, mappings) # :nodoc:
                if mappings.empty?
                    raise ArgumentError, "the connection set is empty"
                end
                if linked?(source_task, sink_task)
                    current_mappings = source_task[sink_task, self]
                    new_mappings = current_mappings.merge(mappings) do |(from, to), old_options, new_options|
                        if old_options.empty? then new_options
                        elsif new_options.empty? then old_options
                        elsif old_options != new_options
                            raise Roby::ModelViolation, "cannot override connection setup with #connect_to (#{old_options} != #{new_options})"
                        end
                        old_options
                    end
                    source_task[sink_task, self] = new_mappings
                else
                    link(source_task, sink_task, mappings)
                end
            end

            def remove_connections(source_task, sink_task, mappings)
                current_mappings = source_task[sink_task, self]
                mappings.each do |source_port, sink_port|
                    current_mappings.delete([source_port, sink_port])
                end
                if current_mappings.empty?
                    unlink(source_task, sink_task)
                end
            end
        end

        ActualDataFlow   = ConnectionGraph.new
        Orocos::TaskContext.include BGL::Vertex

        Flows = Roby::RelationSpace(Component)
        def self.update_connection_policy(old, new)
            if old.empty?
                return new
            elsif new.empty?
                return old
            end

            old = Port.validate_policy(old)
            new = Port.validate_policy(new)
            if old[:type] != new[:type]
                raise ArgumentError, "connection types mismatch: #{old[:type]} != #{new[:type]}"
            end
            type = old[:type]

            if type == :buffer
                if new.size != old.size
                    raise ArgumentError, "connection policy mismatch: #{old} != #{new}"
                end

                old.merge(new) do |key, old_value, new_value|
                    if key == :size
                        [old_value, new_value].max
                    elsif old_value != new_value
                        raise ArgumentError, "connection policy mismatch for #{key}: #{old_value} != #{new_value}"
                    else
                        old_value
                    end
                end
            elsif old == new.slice(*old.keys)
                new
            end
        end

        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source, :dag => false, :weak => true do
            def ensure_has_output_port(name)
                if !model.output_port(name)
                    if model.dynamic_output_port?(name)
                        instanciate_dynamic_output(name)
                    else
                        raise ArgumentError, "#{self} has no output port called #{name}"
                    end
                end
            end

            def ensure_has_input_port(name)
                if !model.input_port(name)
                    if model.dynamic_input_port?(name)
                        instanciate_dynamic_input(name)
                    else
                        raise ArgumentError, "#{self} has no input port called #{name}"
                    end
                end
            end

            def clear_relations
                Flows::DataFlow.remove(self)
                super
            end


            # Forward an input port of a composition to one of its children, or
            # an output port of a composition's child to its parent composition.
            #
            # +mappings+ is a hash of the form
            #
            #   source_port_name => sink_port_name
            #
            # If the +self+ composition is the parent of +target_task+, then
            # source_port_name must be an input port of +self+ and
            # sink_port_name an input port of +target_task+.
            #
            # If +self+ is a child of the +target_task+ composition, then
            # source_port_name must be an output port of +self+ and
            # sink_port_name an output port of +target_task+.
            #
            # Raises ArgumentError if one of the specified ports do not exist,
            # or if +target_task+ and +self+ are not related in the Dependency
            # relation.
            def forward_ports(target_task, mappings)
                if self.child_object?(target_task, Roby::TaskStructure::Dependency)
                    if !fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_input_port(from)
                        target_task.ensure_has_input_port(to)
                    end

                elsif target_task.child_object?(self, Roby::TaskStructure::Dependency)
                    if !target_task.fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        ensure_has_output_port(from)
                        target_task.ensure_has_output_port(to)
                    end
                else
                    raise ArgumentError, "#{target_task} and #{self} are not related in the Dependency relation"
                end

                add_sink(target_task, mappings)
            end

            # Connect a set of ports between +self+ and +target_task+.
            #
            # +mappings+ describes the connections. It is a hash of the form
            #   
            #   [source_port_name, sink_port_name] => connection_policy
            #
            # where source_port_name is a port of +self+ and sink_port_name a
            # port of +target_task+
            #
            # Raises ArgumentError if one of the ports do not exist.
            def connect_ports(target_task, mappings)
                mappings.each do |(out_port, in_port), options|
                    ensure_has_output_port(out_port)
                    target_task.ensure_has_input_port(in_port)
                end

                add_sink(target_task, mappings)
            end

            # Yields the input connections of this task
            def each_input_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_input_connection)
                end

                each_source do |source_task|
                    source_task[self, Flows::DataFlow].each do |(source_port, sink_port), policy|
                        if required_port 
                            if sink_port == required_port
                                yield(source_task, source_port, sink_port, policy)
                            end
                        else
                            yield(source_task, source_port, sink_port, policy)
                        end
                    end
                end
            end

            def each_concrete_input_connection(required_port = nil, &block)
                if !block_given?
                    return enum_for(:each_concrete_input_connection, required_port)
                end

                each_input_connection(required_port) do |source_task, source_port, sink_port, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if source_task.kind_of?(Composition)
                        source_task.each_concrete_input_connection(source_port) do |source_task, source_port, _, connection_policy|
                            begin
                                policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in input chain for #{self}:#{sink_port}: #{e.message}"
                            end

                            yield(source_task, source_port, sink_port, policy)
                        end
                    else
                        yield(source_task, source_port, sink_port, policy)
                    end
                end
                self
            end

            def each_concrete_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_concrete_output_connection, required_port)
                end

                each_output_connection(required_port) do |source_port, sink_port, sink_task, policy|
                    # Follow the forwardings while +sink_task+ is a composition
                    if sink_task.kind_of?(Composition)
                        sink_task.each_concrete_output_connection(sink_port) do |_, sink_port, sink_task, connection_policy|
                            begin
                                policy = RobyPlugin.update_connection_policy(policy, connection_policy)
                            rescue ArgumentError => e
                                raise SpecError, "incompatible policies in output chain for #{self}:#{source_port}: #{e.message}"
                            end
                            yield(source_port, sink_port, sink_task, policy)
                        end
                    else
                        yield(source_port, sink_port, sink_task, policy)
                    end
                end
                self
            end

            # Yields the output connections going out of this task. If an
            # argument is given, only connections going out of this particular
            # port are yield.
            def each_output_connection(required_port = nil)
                if !block_given?
                    return enum_for(:each_output_connection, required_port)
                end

                each_sink do |sink_task, connections|
                    connections.each do |(source_port, sink_port), policy|
                        if required_port
                            if required_port == source_port
                                yield(source_port, sink_port, sink_task, policy)
                            end
                        else
                            yield(source_port, sink_port, sink_task, policy)
                        end
                    end
                end
                self
            end

        end

        module Flows
            class << DataFlow
                attr_accessor :pending_changes
            end

            def DataFlow.modified_tasks
                @modified_tasks ||= ValueSet.new
            end

            def DataFlow.merge_info(source, sink, current_mappings, additional_mappings)
                current_mappings.merge(additional_mappings) do |(from, to), old_options, new_options|
                    RobyPlugin.update_connection_policy(old_options, new_options)
                end
            end
        end
    end
end

