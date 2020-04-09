# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        # This class embeds the basic handling of computations that need to
        # follow the dataflow
        #
        # It provides an interface that allows to propagate information along
        # the dataflow
        #
        # Requirements on the information type:
        #
        # * empty?
        # * merge(value)
        #
        # Subclasses need to redefine the following methods (go to the method
        # documentation for more information)
        #
        # * initial_information(task)
        # * required_information(tasks)
        # * triggering_inputs(task)
        # * propagate_task(task)
        class DataFlowComputation
            attr_reader :result

            attr_reader :triggering_connections

            attr_reader :triggering_dependencies

            attr_reader :missing_ports

            attr_reader :done_ports

            extend Logger::Hierarchy
            include Logger::Hierarchy

            def initialize
                reset
            end

            def has_information_for_port?(task, port_name)
                result.key?(task) &&
                    result[task].key?(port_name)
            end

            def has_final_information_for_port?(task, port_name)
                done_ports.key?(task) &&
                    done_ports[task].include?(port_name) &&
                    has_information_for_port?(task, port_name)
            end

            # Returns the task information stored for the given task
            #
            # The return type is specific to the actual algorithm (i.e. the
            # subclass of DataFlowComputation)
            #
            # @raise ArgumentError if there are no information stored for the given task
            def task_info(task)
                port_info(task, nil)
            end

            # Returns the port information stored for the given port
            #
            # The return type is specific to the actual algorithm (i.e. the
            # subclass of DataFlowComputation)
            #
            # @raise ArgumentError if there are no information stored for the given port
            def port_info(task, port_name)
                if result.key?(task)
                    if result[task].key?(port_name)
                        return result[task][port_name]
                    end
                end
                if port_name
                    raise ArgumentError, "no information currently available for #{task.orocos_name}.#{port_name}"
                else
                    raise ArgumentError, "no information currently available for #{task.orocos_name}"
                end
            end

            # Stores propagation information for the algorithm
            #
            # This class stores a list of ports on which changes will should
            # cause a call to #propagate_task. It is used as values in
            # DataFlowComputation#triggering_connections
            class Trigger
                USE_ALL = 0 # all triggers must have final information
                USE_ANY = 1 # at least one trigger must have final information
                USE_PARTIAL = 2 # can use any added info from any trigger (implies USE_ANY)

                # The list of triggering ports, as [task, port_name] pairs
                attr_reader :ports
                # The propagation mode, as one of USE_ALL, USE_ANY and
                # USE_PARTIAL constants. See constant documentation for more
                # details.
                attr_reader :mode

                def initialize(ports, mode)
                    @ports = ports
                    @mode = mode
                end

                # Called by the algorithm to determine which ports should
                # be propagated given a certain algorithm state +state+.
                #
                # +state+ is a DataFlowComputation object. Only the
                # #has_information_for_port? and
                # #has_final_information_for_port? methods are used.
                def ports_to_propagate(state)
                    if ports.empty?
                        return [], false
                    end

                    complete = false
                    candidates = []
                    ports.each do |args|
                        if state.has_final_information_for_port?(*args)
                            complete = true
                            candidates << args
                        elsif mode == USE_ALL
                            return [], false
                        elsif state.has_information_for_port?(*args)
                            complete = false
                            if mode == USE_PARTIAL
                                candidates << args
                            end
                        end
                    end

                    if mode == USE_ALL
                        unless complete
                            return []
                        end

                        [ports, true]
                    else
                        [candidates, complete]
                    end
                end

                def to_s
                    modes = %w{ALL ANY PARTIAL}
                    "#<Trigger: mode=#{modes[mode]} ports=#{ports.map { |t, p| "#{t}.#{p}" }.sort.join(',')}>"
                end

                def pretty_print(pp)
                    mode = %w{ALL ANY PARTIAL}[self.mode]
                    pp.text mode
                    pp.breakable
                    pp.seplist(ports) do |portdef|
                        task, port = *portdef
                        pp.text "#{task}.#{port}"
                    end
                end
            end

            def reset(tasks = [])
                @result = Hash.new { |h, k| h[k] = {} }
                # Internal variable that is used to detect whether an iteration
                # added information
                @changed = false
                @done_ports = Hash.new { |h, k| h[k] = Set.new }
                @triggering_connections = Hash.new { |h, k| h[k] = {} }
                @triggering_dependencies = Hash.new { |h, k| h[k] = Set.new }
                @missing_ports = {}
            end

            def propagate(tasks)
                reset(tasks)

                debug do
                    debug "#{self.class}: computing on #{tasks.size} tasks"
                    tasks.each do |t|
                        debug "  #{t}"
                    end
                    break
                end

                # Compute the set of ports for which information is required.
                # This is called before #initial_information, so that
                # #initial_information can add the required information if it is
                # available
                @missing_ports = required_information(tasks)
                unless @missing_ports.kind_of?(Hash)
                    raise ArgumentError, "#required_information is supposed to return a Hash, but returned #{@missing_ports}"
                end

                debug ""
                debug "== Gathering Initial Information"
                tasks.each do |task|
                    debug { "computing initial information for #{task}" }

                    log_nest(4) do
                        initial_information(task)
                        if connections = triggering_port_connections(task)
                            triggering_connections[task] = connections
                            triggering_dependencies[task] = connections.map do |port_name, triggers|
                                triggers.ports.map(&:first)
                            end

                            debug do
                                debug "#{connections.size} triggering connections for #{task}"
                                connections.each do |port_name, info|
                                    debug "    for #{port_name}"
                                    log_nest(8) do
                                        log_pp :debug, info
                                    end
                                end
                                break
                            end
                        end
                    end
                end

                debug ""
                debug "== Propagation"
                remaining_tasks = tasks.dup
                until missing_ports.empty?
                    remaining_tasks = remaining_tasks
                                      .sort_by { |t| triggering_dependencies[t].size }

                    @changed = false
                    remaining_tasks.delete_if do |task|
                        triggering_connections[task].delete_if do |port_name, triggers|
                            next if has_final_information_for_port?(task, port_name)

                            to_propagate, complete = triggers.ports_to_propagate(self)
                            debug do
                                if to_propagate.empty?
                                    debug { "nothing to propagate to #{task}.#{port_name}" }
                                    debug { "    complete: #{complete}" }
                                else
                                    debug { "propagating information to #{task}.#{port_name}" }
                                    debug { "    complete: #{complete}" }
                                    to_propagate.each do |info|
                                        debug "    #{info.compact.join('.')}"
                                    end
                                end
                                break
                            end

                            to_propagate.each do |info|
                                begin
                                    add_port_info(task, port_name, port_info(*info))
                                rescue Exception => e
                                    raise DataflowPropagationError.new(e, task, port_name), "while propagating information from port #{info} to #{port_name} on #{task}, #{e.message}"
                                end
                            end
                            if complete
                                done_port_info(task, port_name)
                                true
                            else
                                false
                            end
                        end

                        propagate_task(task)
                    end

                    unless @changed
                        break
                    end
                end

                if !missing_ports.empty?
                    debug do
                        debug "found fixed point, breaking out of propagation loop with #{missing_ports.size} missing ports"
                        debug "removing partial port information"
                        break
                    end
                    result.delete_if do |task, port_info|
                        port_info.delete_if do |port, info|
                            if info.empty?
                                debug do
                                    debug "  #{task}.#{port} (empty)"
                                    break
                                end
                                true

                            elsif !has_final_information_for_port?(task, port)
                                debug do
                                    debug "  #{task}.#{port} (not finalized)"
                                    break
                                end
                                true
                            end
                        end
                        port_info.empty?
                    end
                else
                    debug "done computing all required port information"
                end

                result
            end

            def set_port_info(task, port_name, info)
                if !has_information_for_port?(task, port_name)
                    add_port_info(task, port_name, info)
                else
                    @result[task][port_name] = info
                end
            end

            # Register information about the given task's port.
            #
            # If some information is already available, merge the new +info+
            # object with what exists. Use #set_port_info to reset the current
            # information with the new object.
            def add_port_info(task, port_name, info)
                if done_ports[task].include?(port_name)
                    done_at = @done_at[[task, port_name]] if @done_at
                    raise ModifyingFinalizedPortInfo.new(task, port_name, done_at, self.class.name), "trying to change port information for #{task}.#{port_name} after done_port_info has been called"
                end

                if !has_information_for_port?(task, port_name)
                    @changed = true
                    @result[task][port_name] = info
                else
                    begin
                        @changed = @result[task][port_name].merge(info)
                    rescue Exception => e
                        raise e, "while adding information to port #{port_name} on #{task}, #{e.message}", e.backtrace
                    end
                end
            end

            # Deletes all available information about the specified port
            def remove_port_info(task, port_name)
                unless @result.key?(task)
                    return
                end

                task_info = @result[task]
                task_info.delete(port_name)
                if task_info.empty?
                    @result.delete(task)
                end
            end

            # Called when all information on +task+.+port_name+ has been added
            def done_port_info(task, port_name)
                unless done_ports[task].include?(port_name)
                    @changed = true

                    if has_information_for_port?(task, port_name)
                        if port_info(task, port_name).empty?
                            remove_port_info(task, port_name)
                        end
                    end

                    done_ports[task] << port_name
                    if missing_ports.key?(task)
                        missing_ports[task].delete(port_name)
                        if missing_ports[task].empty?
                            missing_ports.delete(task)
                        end
                    end
                end

                debug do
                    debug "done computing information for #{task}.#{port_name}"
                    log_nest(4) do
                        if has_information_for_port?(task, port_name)
                            log_pp(:debug, port_info(task, port_name))
                        else
                            debug "no stored information"
                        end
                    end
                    @done_at ||= {}
                    @done_at[[task, port_name]] = caller
                    break
                end
            end

            # Registers information about +task+ that is independent of the
            # connection graph, to seed the algorithm
            #
            # The information must be added using #add_port_info
            def initial_information(task)
                raise NotImplementedError
            end

            # Returns the list of ports whose information can be propagated to a
            # port in +task+
            #
            # The returned value is a hash of the form
            #
            #   port_name => [Set([other_task, other_port_name]), boolean]
            #
            # where +port_name+ is a port in +task+ and the set is a set of
            # ports whose information can be propagated to add information on
            # +port_name+.
            #
            # If the boolean is false, the information will be propagated only
            # if all the listed ports have information. Otherwise, it will be as
            # soon as one has some information
            #
            # The default implementation calls a method +triggering_inputs+ that
            # simply returns a list of ports in +task+ whose connections are
            # triggering.
            def triggering_port_connections(task)
                result = {}
                connections = Set.new

                triggering_inputs(task).each do |port|
                    task.each_concrete_input_connection(port.name) do |from_task, from_port, to_port, _|
                        connections << [from_task, from_port]
                    end
                    unless connections.empty?
                        result[port.name] = Trigger.new(connections, Trigger::USE_ALL)
                        connections = Set.new
                    end
                end
                result
            end

            # Returns the list of input ports in +task+ that should trigger a
            # recomputation of the information for +task+
            def triggering_inputs(task)
                raise NotImplementedError
            end

            # Returns the set of objects for which information is required as an
            # output of the algorithm
            #
            # The returned value is a map:
            #
            #   task => ports
            #
            # Where +ports+ is the set of port names that are required on
            # +task+. +nil+ can be used to denote the task itself.
            def required_information(tasks)
                raise NotImplementedError
            end

            # Propagate information on +task+. Returns true if all information
            # that can be computed has been (i.e. if calling #propagate_task on
            # the same task again will never add new information)
            def propagate_task(task)
                raise NotImplementedError
            end

            # Maps the tasks stored in the dataflow dynamics information to the
            # ones that +merge_solver+ is pointing to
            def apply_merges(merge_solver)
                @result = result.transform_keys do |task|
                    merge_solver.replacement_for(task)
                end
                @missing_ports = missing_ports.transform_keys do |task|
                    merge_solver.replacement_for(task)
                end
                @done_ports = done_ports.transform_keys do |task|
                    merge_solver.replacement_for(task)
                end
            end
        end
    end
end
