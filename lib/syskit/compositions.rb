module Orocos
    module RobyPlugin
        module CompositionModel
            include Model

            attr_accessor :name

            def new_submodel(name, system)
                klass = super()
                klass.name = name
                klass.system = system
                klass
            end

            attribute(:children) { Hash.new }

            def [](name)
                children[name]
            end
            def add_child(name, task)
                children[name.to_s] = task
            end

            def add(model_name, options = Hash.new)
                options = Kernel.validate_options options, :as => model_name
                task = system.get(model_name)

                add_child(options[:as], task)
                task
            end

            # The set of connections in this composition, as a list of [output,
            # input] pairs
            attribute(:connections) { Array.new }

            # Outputs exported from this composition
            attribute(:outputs)  { Hash.new }
            # Inputs imported from this composition
            attribute(:inputs)   { Hash.new }

            def autoconnect(*names)
                @autoconnect = if names.empty? 
                                   children.keys
                               else
                                   names
                               end
            end

            def compute_autoconnection
                if @autoconnect && !@autoconnect.empty?
                    do_autoconnect(@autoconnect)
                end
            end

            # Automatically compute the connections that can be done in the
            # limits of this composition, and returns the set.
            #
            # Connections are determined by port direction and type name.
            #
            # It raises AmbiguousConnections if autoconnection does not know
            # what to do.
            def do_autoconnect(children_names)
                result = Array.new
                child_inputs  = Hash.new { |h, k| h[k] = Array.new }
                child_outputs = Hash.new { |h, k| h[k] = Array.new }

                # Gather all child input and outputs
                children_names.each do |name|
                    sys = children[name]
                    sys.each_input do |in_port|
                        if !exported_port?(in_port)
                            child_inputs[in_port.type_name] << [name, in_port.name]
                        end
                    end

                    sys.each_output do |out_port|
                        if !exported_port?(out_port)
                            child_outputs[out_port.type_name] << [name, out_port.name]
                        end
                    end
                end

                # Make sure there is only one input for one output, and add the
                # connections
                child_inputs.each do |typename, in_ports|
                    in_ports.each do |in_child_name, in_port_name|
                        out_ports = child_outputs[typename]
                        out_ports.delete_if do |out_child_name, out_port_name|
                            out_child_name == in_child_name
                        end
                        next if out_ports.empty?

                        if out_ports.size > 1
                            # Check for port name
                            same_name = out_ports.find_all { |_, out_port_name| out_port_name == in_port_name }
                            if same_name.size == 1
                                out_ports = same_name
                            end
                        end

                        if out_ports.size > 1
                            out_port_names = out_ports.map { |child_name, port_name| "#{child_name}.#{port_name}" }
                            raise Ambiguous, "multiple output candidates in #{name} for #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
                        end

                        out_port = out_ports.first
                        result << [out_port[0], out_port[1], in_child_name, in_port_name]
                    end
                end

                connections.concat(result)
            end

            def export(port, name = nil)
                name ||= port.name
                case port
                when OutputPort
                    outputs[name] = port
                when InputPort
                    inputs[name] = port
                else
                    raise TypeError, "invalid port #{port}"
                end
            end

            def exported_port?(port_model)
                outputs.values.any? { |p| port_model == p } ||
                    inputs.values.any? { |p| port_model == p }
            end

            def each_output(&block)
                if !@exported_outputs
                    @exported_outputs = outputs.map do |name, p|
                        p.class.new(self, name, p.type_name, p.port_model)
                    end
                end
                @exported_outputs.each(&block)
            end
            def each_input(&block)
                if !@exported_inputs
                    @exported_inputs = inputs.map do |name, p|
                        p.class.new(self, name, p.type_name, p.port_model)
                    end
                end
                @exported_inputs.each(&block)
            end

            attribute(:connections) { Array.new }

            def instanciate(engine, arguments = Hash.new)
                arguments, task_arguments = Model.filter_instanciation_arguments(arguments)
                selection = arguments[:selection]

                engine.plan.add(self_task = new(task_arguments))

                children_tasks = Hash.new
                children.each do |child_name, child_model|
                    role = if child_name == child_model.name
                               Set.new
                           else [child_name].to_set
                           end

                    # The model this composition actually requires. It may be
                    # different than child_model in case of explicit selection
                    dependent_model = child_model

                    # Check if an explicit selection applies
                    selected_object = (selection[child_model] || selection[child_name])
                    if selected_object
                        # Check that the selection is actually valid
                        if !selected_object.fullfills?(child_model)
                            raise SpecError, "cannot select #{submodel} for #{child_model}: #{submodel} is not a specialized model for #{child_model}"
                        end
                        # Now, +selected_object+ can either be a task instance
                        # or a task model. Check ...
                        if selected_object.kind_of?(child_model)
                            task = selected_object # selected an instance explicitely
                        else
                            child_model = selected_object
                        end
                    end

                    if !task
                        # Filter out arguments: check if some of the mappings
                        # are prefixed by "child_name.", in which case we
                        # transform the mapping for our child
                        child_arguments = arguments.dup
                        child_selection = Hash.new
                        arguments[:selection].each do |from, to|
                            if from.respond_to?(:to_str) && from =~ /^#{child_name}\./
                                from = from.gsub(/^#{child_name}\./, '')
                                sel_from = engine.apply_selection(from)
                                from = sel_from || from
                            end
                            child_arguments[:selection][from] = to
                        end
                        task = child_model.instanciate(engine, child_arguments)
                    end

                    children_tasks[child_name] = task
                    self_task.depends_on(task, :model => [dependent_model, task.arguments], :roles => role)
                end

                connections.each do |out_name, out_port, in_name, in_port|
                    children_tasks[out_name].add_sink(children_tasks[in_name], [out_port, in_port])
                end
                self_task
            end
        end

        # Module in which all composition models are registered
        module Compositions
        end

        class Composition < Component
            extend CompositionModel

            def ids; arguments[:ids] end
        end
    end
end

