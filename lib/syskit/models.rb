require 'orocos/spec/base'

module Orocos
    module RobyPlugin
        # Generic module included in all classes that are used as models
        module Model
            attr_accessor :system

            def to_s
                supermodels = ancestors.map(&:name)
                i = supermodels.index("Roby::Task")
                supermodels = supermodels[0, i]
                supermodels.each do |name|
                    name.gsub!(/Orocos::RobyPlugin::(.*)/, "\\1")
                end
            "#<#{supermodels.join(" < ")}>"
            end
            def new_submodel
                klass = Class.new(self)
                klass.system = system
                klass
            end
        end

        class Component < ::Roby::Task
        end

        # Module that defines the model-level methods for devices
        module DeviceModel
            # Name of this device
            attr_reader :device_name
            attr_reader :trigger
            attr_reader :com_bus

            def new_submodel(name, options = Hash.new)
                model = Roby::TaskModelTag.new
                model.extend DeviceModel
                model.include self

                options = Kernel.validate_options options,
                    :period       => nil,
                    :triggered_by => nil,
                    :com_bus      => nil

                if options[:period] && options[:triggered_by]
                    raise SpecError, "a device cannot be both periodic and explicitely triggered"
                end

                model.instance_variable_set :@device_name, name.to_str
                model.instance_variable_set :@trigger,
                    options.delete(:period) || options.delete(:triggered_by)
                model.instance_variable_set :@com_bus,
                    options.delete(:com_bus)
                model
            end

            def periodic?; @trigger.kind_of?(Numeric) end
            def period; trigger if periodic? end

            def instanciate(plan, arguments = Hash.new)
                arguments = {:device_name => name}.merge(arguments)
                if !@task_model
                    @task_model = Class.new(Component) do
                        abstract
                    end
                    @task_model.include self
                end

                plan.add(task = @task_model.new(arguments))
                task
            end

            def to_s
            "#<Device: #{device_name}>"
            end
        end

        Device = Roby::TaskModelTag.new do
            extend DeviceModel
        end

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
                task = system.device(model_name) ||
                    system.get(model_name)

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

            def resolve_composition
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
                            raise Orocos::Spec::AmbiguousConnections, "multiple output candidates in #{name} for #{in_child_name}.#{in_port_name} (of type #{typename}): #{out_port_names.join(", ")}"
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

            def instanciate(plan, arguments = Hash.new)
                plan.add(self_task = new(arguments))

                children_tasks = Hash.new
                children.each do |child_name, child_model|
                    task = child_model.instanciate(plan, arguments)
                    children_tasks[child_name] = task
                    self_task.depends_on(task, :model => child_model, :roles => [child_name].to_set)
                end

                connections.each do |out_name, out_port, in_name, in_port|
                    children_tasks[out_name].add_sink(children_tasks[in_name], [out_port, in_port])
                end
                self_task
            end
        end

        class Composition < Component
            extend CompositionModel

            def ids; arguments[:ids] end
        end

        Flows = Roby::RelationSpace(Component)
        Flows.relation :DataFlow, :child_name => :sink, :parent_name => :source
    end
end

