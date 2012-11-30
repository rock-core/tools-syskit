module Syskit
        # Exception raised when CompositionChild#method_missing is called to
        # resolve a port but the port name is ambiguous
        class AmbiguousChildConnection < ArgumentError
            attr_reader :composition_model
            attr_reader :out_p
            attr_reader :in_p

            def initialize(composition_model, out_p, in_p)
                @composition_model = composition_model
                @out_p, @in_p = out_p, in_p
            end

            def pretty_print(pp)
                out_explicit = out_p.kind_of?(OutputPort)
                in_explicit  = in_p.kind_of?(InputPort)
                if in_explicit && out_explicit
                    pp.text "cannot connect #{in_p.short_name} to #{out_p.short_name}: incompatible types"
                    in_model = in_p.child.models
                    out_model = out_p.child.models
                elsif in_explicit
                    pp.text "cannot find a match for #{in_p.short_name} in #{out_p.short_name}"
                    in_model = in_p.child.models
                    out_model = out_p.models
                elsif out_explicit
                    pp.text "cannot find a match for #{out_p.short_name} in #{in_p.short_name}"
                    in_model = in_p.models
                    out_model = out_p.child.models
                else
                    pp.text "no compatible ports found while connecting #{out_p.short_name} to #{in_p.short_name}"
                    in_model  = in_p.models
                    out_model = out_p.models
                end

                [["Output candidates", out_model, :each_output_port],
                    ["Input candidates", in_model, :each_input_port]].
                    each do |name, models, each|
                        pp.breakable
                        pp.text name
                        pp.breakable
                        pp.seplist(models) do |m|
                            pp.text m.short_name
                            pp.nest(2) do
                                pp.breakable
                                pp.seplist(m.send(each)) do |p|
                                    p.pretty_print(pp)
                                end
                            end
                        end
                    end
            end
        end

        # Exception raised when CompositionChild#method_missing is called to
        # resolve a port but the port name is ambiguous
        class AmbiguousChildPort < RuntimeError
            attr_reader :composition_child
            attr_reader :port_name
            attr_reader :candidates

            def initialize(composition_child, port_name, candidates)
                @composition_child, @port_name, @candidates =
                    composition_child, port_name, candidates
            end

            def pretty_print(pp)
                pp.text "#{port_name} is ambiguous on the child #{composition_child.child_name} of"
                pp.breakable
                composition_child.composition.pretty_print(pp)
                pp.breakable
                pp.text "Candidates:"
                pp.nest(2) do
                    pp.breakable
                    pp.seplist(candidates) do |c|
                        pp.text c
                    end
                end
            end
        end

        # Compositions, i.e. grouping of components and/or other compositions
        # that perform a given function.
        #
        # Compositions are used to regroup components and/or other compositions
        # in functional groups.
        #
        # See the Models::Composition for class-level methods
        class Composition < Component
            extend Models::Composition

            @name = "Syskit::Composition"
            @strict_specialization_selection = true

            terminates

            def initialize(options = Hash.new)
                @child_selection = Hash.new
                super
            end

            # A name => SelectedChild mapping of the selection result during
            # #instanciate
            attr_reader :child_selection

            inherited_enumerable(:child, :children, :map => true) { Hash.new }
            inherited_enumerable(:child_constraint, :child_constraints, :map => true) { Hash.new { |h, k| h[k] = Array.new } }
            inherited_enumerable(:default_specialization, :default_specializations, :map => true) { Hash.new }

            # The set of connections specified by the user for this composition
            def self.promote_explicit_connection(connections)
                children, mappings = *connections

                mappings_out =
                    if child_out = self.children[children[0]]
                        child_out.port_mappings
                    else Hash.new
                    end
                mappings_in =
                    if child_in = self.children[children[1]]
                        child_in.port_mappings
                    else Hash.new
                    end

                mapped = Hash.new
                mappings.each do |(port_name_out, port_name_in), options|
                    port_name_out = (mappings_out[port_name_out] || port_name_out)
                    port_name_in  = (mappings_in[port_name_in]   || port_name_in)
                    mapped[[port_name_out, port_name_in]] = options
                end
                [children, mapped]
            end
            inherited_enumerable(:explicit_connection, :explicit_connections) { Hash.new { |h, k| h[k] = Hash.new } }
            # The set of connections automatically generated by
            # compute_autoconnection
            #
            # #do_autoconnect computes all connections for the +self+ model, so
            # there is no need to use inherited_enumerable here
            class << self
                attr_accessor :automatic_connections
            end

            def self.promote_exported_port(export_name, port)
                if new_child = children[port.component_model.child_name]
                    if new_port_name = new_child.port_mappings[port.name]
                        result = send(port.component_model.child_name).find_port(new_port_name)
                        result = result.dup
                        result.name = export_name
                        result
                    else
                        port
                    end
                else
                    port
                end
            end

            # Outputs exported from this composition
            def self.promote_exported_output(export_name, port)
                exported_outputs[export_name] = promote_exported_port(export_name, port)
            end

            inherited_enumerable(:exported_output, :exported_outputs, :map => true)  { Hash.new }
            # Inputs imported from this composition
            def self.promote_exported_input(export_name, port)
                exported_inputs[export_name] = promote_exported_port(export_name, port)
            end
            inherited_enumerable(:exported_input, :exported_inputs, :map => true)  { Hash.new }
            # Configurations defined on this composition model
            inherited_enumerable(:configuration, :configurations, :map => true)  { Hash.new }

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
            def self.conf(name, mappings = Hash.new)
                configurations[name] = mappings
            end

            # Returns the configuration definition for the given
            # configuration(s)
            #
            # Note that unlike ConfigurationManager, only one configuration
            # can be selected (they cannot be overlaid on top of each other)
            #
            # The returned value is a mapping from child names to the
            # configurations that should be applied to them, i.e. for the
            # 'narrow' configuration used as an example in Composition.conf,
            #
            #   conf(['narrow'])
            #
            # would return
            #
            #   'monitoring' => ['default', 'narrow_window'],
            #   'sonar' => ['default', 'narrow_window']
            def conf(names)
                if names.size != 1
                    raise ArgumentError, "unlike with ConfigurationManager, only one  configuration can be selected on compositions"
                end

                result = Hash.new
                found_something = false
                model.each_configuration(names.first.to_s, false) do |values|
                    found_something = true
                    result = values.merge(result)
                end
                if !found_something
                    if names == ['default']
                        ConfigurationManager.info "required default configuration on composition #{task}, but #{task.model.short_name} has no registered default configurations"
                        return result
                    else
                        raise ArgumentError, "#{self} has no declared configuration called #{names.join(", ")}"
                    end
                end
                result
            end

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def fullfills?(models, args = Hash.new) # :nodoc:
                models = [models] if !models.respond_to?(:each)
                compo, normal = models.partition { |m| m <= Composition }
                if !super(normal, args)
                    return false
                elsif compo.empty?
                    return true
                else
                    (self.model <= compo.first) ||
                        compo.first.parent_model_of?(self.model)
                end
            end

            # Reimplemented from Roby::Task to take into account the multiple
            # inheritance mechanisms that is the composition specializations
            def self.fullfills?(models) # :nodoc:
                models = [models] if !models.respond_to?(:each)
                compo, normal = models.partition { |m| m <= Composition }
                if !super(normal)
                    return false
                elsif compo.empty?
                    return true
                else
                    (self <= compo.first) ||
                        compo.first.parent_model_of?(self)
                end
            end

            # Overriden from Roby::Task
            #
            # will return false if any of the children is not executable.
            def executable? # :nodoc:
                if !super
                    return false
                elsif @executable
                    return true
                end

                each_child do |child_task, _|
                    if child_task.kind_of?(TaskContext)
                        if !child_task.orocos_task
                            return false
                        end
                    elsif child_task.kind_of?(Component)
                        if !child_task.executable?
                            return false
                        end
                    end
                end
                return true
            end

            # Returns the actual port that is currently used to provide data to
            # an exported output, or returns nil if there is currently none.
            #
            # This is used to discover which actual component is currently
            # providing a port on the composition. In other words, when one does
            #
            #   composition 'Test' do
            #       src = add Source
            #       export src.output
            #   end
            #
            # then, once the composition is instanciated,
            # test_task.find_output_port('output') will return src_task.output where
            # src_task is the actual component used for the Source child. If, at
            # the time of the call, no such component is present, then
            # output_port will return nil.
            #
            # See also #input_port
            def find_output_port(name)
                real_task, real_port = resolve_output_port(name)
                real_task.find_output_port(real_port)
            rescue ArgumentError
            end

            # Helper method for #output_port and #resolve_port
            def resolve_output_port(name) # :nodoc:
                if !(port = model.find_output_port(name))
                    raise ArgumentError, "no output port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Returns the actual port that is currently used to get data from
            # an exported input, or returns nil if there is currently none.
            #
            # See #output_port for details.
            def find_input_port(name)
                real_task, real_port = resolve_input_port(name)
                real_task.find_input_port(real_port)
            rescue ArgumentError
            end

            # Helper method for #output_port and #resolve_port
            #
            # It returns a component instance and a port name.
            def resolve_input_port(name) # :nodoc:
                if !(port = model.find_input_port(name.to_str))
                    raise ArgumentError, "no input port named '#{name}' on '#{self}'"
                end
                resolve_port(port)
            end

            # Internal implementation of #output_port and #input_port
            #
            # It returns the [component instance, port name] pair which
            # describes the port which is connected to +exported_port+, where
            # +exported_port+ is a port of this composition.
            #
            # In other words, it returns the port that is used to produce data
            # for the exported port +exported_port+.
            def resolve_port(exported_port) # :nodoc:
                role = exported_port.child.child_name
                task = child_from_role(role, false)
                if !task
                    return
                end

                port_name = map_child_port(role, exported_port.actual_name)
                if task.kind_of?(Composition)
                    if exported_port.kind_of?(OutputPort)
                        return task.resolve_output_port(port_name)
                    else
                        return task.resolve_input_port(port_name)
                    end
                else
                    return task, port_name
                end
            end

            def map_child_port(child_name, port_name)
                if mapped = model.find_child(child_name).port_mappings[port_name]
                    return mapped
                elsif mapped = child_selection[child_name].port_mappings[port_name]
                    return mapped
                else
                    port_name
                end
            end

            # Helper for #added_child_object and #removing_child_object
            #
            # It adds the task to Flows::DataFlow.modified_tasks whenever the
            # DataFlow relations is changed in a way that could require changing
            # the underlying Orocos components connections.
            def dataflow_change_handler(child, mappings) # :nodoc:
                return if !plan || !plan.real_plan.executable?

                if child.kind_of?(TaskContext)
                    Flows::DataFlow.modified_tasks << child
                elsif child_object?(child, Roby::TaskStructure::Dependency)
                    mappings ||= self[child, Flows::DataFlow]
                    mappings.each_key do |source_port, sink_port|
                        real_task, _ = resolve_input_port(source_port)
                        if real_task && !real_task.transaction_proxy? # can be nil if the child has been removed
                            Flows::DataFlow.modified_tasks << real_task
                        end
                    end

                else
                    mappings ||= self[child, Flows::DataFlow]
                    mappings.each_key do |source_port, sink_port|
                        real_task, _ = resolve_output_port(source_port)
                        if real_task && !real_task.transaction_proxy? # can be nil if the child has been removed
                            Flows::DataFlow.modified_tasks << real_task
                        end
                    end
                end
            end

            # Called when a new child is added to this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def added_child_object(child, relations, mappings) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, mappings)
                end
            end

            # Called when a child is removed from this composition.
            #
            # It updates Flows::DataFlow.modified_tasks so that the engine can
            # update the underlying task's connections
            def removing_child_object(child, relations) # :nodoc:
                super if defined? super

                if !transaction_proxy? && !child.transaction_proxy? && relations.include?(Flows::DataFlow)
                    dataflow_change_handler(child, nil)
                end
            end

            def fullfills?(models, arguments = Hash.new)
                if !models.respond_to?(:map)
                    models = [models]
                end

                models = models.map do |other_model|
                    if other_model <= Composition
                        if !(other_model.applied_specializations - model.applied_specializations).empty?
                            return false
                        end
                        other_model.root_model
                    else
                        other_model
                    end
                end
                return super(models, arguments)
            end


            # Proxy returned by the child_name_child handler
            #
            # This is used to perform port mapping if needed
            class CompositionChildInstance
                def initialize(composition_task, child_name, child_task)
                    @composition_task, @child_name, @child_task = composition_task, child_name, child_task
                end
                def as_plan
                    @child_task
                end

                def connect_ports(target_task, mappings)
                    mapped_connections = Hash.new
                    mappings.map do |(source, sink), policy|
                        source = find_output_port(source).name
                        mapped_connections[[source, sink]] = policy
                    end
                    @child_task.connect_ports(target_task, mapped_connections)
                end

                def disconnect_ports(target_task, mappings)
                    mappings = mappings.map do |source, sink|
                        source = find_output_port(source).name
                        [source, sink]
                    end
                    @child_task.disconnect_ports(target_task, mappings)
                end

                def find_input_port(port_name)
                    mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                    @child_task.find_input_port(mapped_port_name)
                end

                def find_output_port(port_name)
                    mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                    @child_task.find_output_port(mapped_port_name)
                end

                def method_missing(m, *args, &block)
                    if m.to_s =~ /^(\w+)_port$/
                        port_name = $1
                        mapped_port_name = @composition_task.map_child_port(@child_name, port_name)
                        if port = @child_task.find_input_port(mapped_port_name)
                            return port
                        elsif port = @child_task.find_output_port(mapped_port_name)
                            return port
                        else raise NoMethodError, "task #{@child_task}, child #{@child_name} of #{@composition_task}, has no port called #{port_name}"
                        end
                    end
                    @child_task.send(m, *args, &block)
                end
            end

            def method_missing(m, *args, &block)
                if args.empty? && !block
                    if m.to_s =~ /^(\w+)_child$/
                        child_name = $1
                        # Verify that the child exists
                        child_task = child_from_role(child_name)
                        return CompositionChildInstance.new(self, child_name, child_task)
                    end
                end
                super
            end
        end
end

