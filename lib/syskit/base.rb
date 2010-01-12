module Orocos
    # Roby is a plan management component, i.e. a supervision framework that is
    # based on the concept of plans.
    #
    # This module includes both the Roby bindings, i.e. what allows to represent
    # Orocos task contexts and deployment processes in Roby, and a model-based
    # system configuration environment.
    module RobyPlugin
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

        Flows = Roby::RelationSpace(Component)
        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source, :dag => false do
            def forward_ports(target_task, mappings)
                if self.child_object?(target_task, Roby::TaskStructure::Dependency)
                    if !fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        if !model.input_port(from) && !model.dynamic_input_port?(from)
                            raise ArgumentError, "#{self} has no input port called #{from}"
                        end
                        if !target_task.model.input_port(to) && !target_task.model.dynamic_input_port?(to)
                            raise ArgumentError, "#{target_task.model} has no input port called #{to}"
                        end
                    end
                elsif target_task.child_object?(self, Roby::TaskStructure::Dependency)
                    if !target_task.fullfills?(Composition)
                        raise ArgumentError, "#{self} is not a composition"
                    end

                    mappings.each do |(from, to), options|
                        if !model.output_port(from) && !model.dynamic_output_port?(from)
                            raise ArgumentError, "#{self} has no output port called #{from}"
                        end
                        if !target_task.model.output_port(to) && !target_task.model.dynamic_output_port?(to)
                            raise ArgumentError, "#{target_task.model} has no output port called #{to}"
                        end
                    end
                else
                    raise ArgumentError, "#{target_task} and #{self} are not related in the Dependency relation"
                end

                add_connections(target_task, mappings)
            end

            def connect_ports(target_task, mappings)
                mappings.each do |(out_port, in_port), options|
                    if !model.output_port(out_port) && !model.dynamic_output_port?(out_port)
                        raise ArgumentError, "#{self} has no output port called #{out_port}"
                    end
                    if !target_task.model.input_port(in_port) && !target_task.model.dynamic_input_port?(in_port)
                        raise ArgumentError, "#{target_task.model} has no input port called #{in_port}"
                    end
                end
                add_connections(target_task, mappings)
            end

            # Helper class for #connect_to and #forward_to
            def add_connections(target_task, mappings) # :nodoc:
                if mappings.empty?
                    raise ArgumentError, "the connection set is empty"
                end
                if child_object?(target_task, Flows::DataFlow)
                    current_mappings = self[target_task, Flows::DataFlow]
                    self[target_task, Flows::DataFlow] = current_mappings.merge(mappings) do |(from, to), old_options, new_options|
                        if old_options != new_options
                            raise Roby::ModelViolation, "cannot override connection setup with #connect_to"
                        end
                        old_options
                    end
                else
                    add_sink(target_task, mappings)
                end
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
                        source_task.each_concrete_input_connection(source_port) do |source_task, source_port, _, policy|
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
                        sink_task.each_concrete_output_connection(sink_port) do |_, sink_port, sink_task, policy|
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
            end
        end
    end
end

