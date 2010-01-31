require 'logger'
require 'utilrb/logger'
module Orocos
    # Roby is a plan management component, i.e. a supervision framework that is
    # based on the concept of plans.
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

        # Generic module included in all classes that are used as models
        module Model
            # The SystemModel instance this model is attached to
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

        module ComponentModel
            def port(name)
                name = name.to_str
                output_port(name) || input_port(name)
            end

            def each_output(&block)
                orogen_spec.each_output_port(&block)
            end

            def each_input(&block)
                orogen_spec.each_input_port(&block)
            end

            def each_port(&block)
                if block_given?
                    each_input(&block)
                    each_output(&block)
                    self
                else
                    enum_for(:each_port)
                end
            end

            def dynamic_output_port?(name)
                orogen_spec.dynamic_output_port?(name)
            end

            def dynamic_input_port?(name)
                orogen_spec.dynamic_input_port?(name)
            end

            def output_port(name)
                name = name.to_str
                each_output.find { |p| p.name == name }
            end

            def input_port(name)
                name = name.to_str
                each_input.find { |p| p.name == name }
            end
        end

        # Base class for models that represent components (TaskContext,
        # Composition)
        class Component < ::Roby::Task
            extend ComponentModel

            # The Robot instance we are running on
            attr_accessor :robot

            inherited_enumerable(:main_data_source, :main_data_sources) { Set.new }
            inherited_enumerable(:data_source, :data_sources, :map => true) { Hash.new }

            def self.instanciate(engine, arguments = Hash.new)
                _, task_arguments = Model.filter_instanciation_arguments(arguments)
                engine.plan.add(task = new(task_arguments))
                task.robot = engine.robot
                task
            end

            attribute(:instanciated_dynamic_outputs) { Hash.new }
            attribute(:instanciated_dynamic_inputs) { Hash.new }

            def output_port_model(name)
                if port_model = model.orogen_spec.each_output_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_outputs[name]
                end
            end

            def input_port_model(name)
                if port_model = model.orogen_spec.each_input_port.find { |p| p.name == name }
                    port_model
                else instanciated_dynamic_inputs[name]
                end
            end

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
                        return Roby.app.orocos_engine.all_inputs_connected?(self)
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
                    self_inputs[sink_port] = [source_task, source_port, policy]
                end
                target_inputs = target_task.each_source.to_value_set
                target_inputs.each do |input_task|
                    not_compatible = input_task.each_concrete_input_connection.any? do |source_task, source_port, sink_port, policy|
                        if same_port = self_inputs[sink_port]
                            same_port[0] != source_task || same_port[1] != source_port
                        end
                    end
                    return false if not_compatible
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

        ActualFlows = Roby::RelationSpace(Orocos::TaskContext)
        ActualFlows.relation :DataFlow, :child_name => :actual_sink, :parent_name => :actual_source, :dag => false, :weak => true

        Flows = Roby::RelationSpace(Component)
        def self.add_connections(source_task, sink_task, mappings, relation) # :nodoc:
            if mappings.empty?
                raise ArgumentError, "the connection set is empty"
            end
            if source_task.child_object?(sink_task, relation)
                current_mappings = source_task[sink_task, relation]
                source_task[sink_task, relation] = current_mappings.merge(mappings) do |(from, to), old_options, new_options|
                    if old_options.empty? then new_options
                    elsif new_options.empty? then old_options
                    elsif old_options != new_options
                        raise Roby::ModelViolation, "cannot override connection setup with #connect_to (#{old_options} != #{new_options})"
                    end
                    old_options
                end
            else
                source_task.add_child_object(sink_task, relation, mappings)
            end
        end
        def self.remove_connections(source_task, sink_task, mappings, relation)
            current_mappings = source_task[sink_task, relation]
            mappings.each do |source_port, sink_port|
                current_mappings.delete([source_port, sink_port])
            end
            if current_mappings.empty?
                source_task.remove_child_object(sink_task, relation)
            end
        end

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

                RobyPlugin.add_connections(self, target_task, mappings, Flows::DataFlow)
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

                RobyPlugin.add_connections(self, target_task, mappings, Flows::DataFlow)
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

