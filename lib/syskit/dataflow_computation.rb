module Orocos
    module RobyPlugin
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

            def has_information_for_port?(task, port_name)
                result.has_key?(task) && result[task].has_key?(port_name)
            end

            def has_final_information_for_port?(task, port_name)
                done_ports[task].include?(port_name) && has_information_for_port?(task, port_name)
            end

            def port_info(task, port_name)
                if result.has_key?(task)
                    if result[task].has_key?(port_name)
                        return result[task][port_name]
                    end
                end
                if port_name
                    raise ArgumentError, "no information currently available for #{task.orocos_name}.#{port_name}"
                else
                    raise ArgumentError, "no information currently available for #{task.orocos_name}"
                end
            end

            def propagate(tasks)
                # Get the periods from the activities themselves directly (i.e.
                # not taking into account the port-driven behaviour)
                #
                # We also precompute relevant connections, as they won't change
                # during the computation
                @result = Hash.new { |h, k| h[k] = Hash.new }
                # Internal variable that counts the number of ports registered
                # in @result
                @result_size = 0
                @done_ports = Hash.new { |h, k| h[k] = Set.new }
                @triggering_connections  = Hash.new { |h, k| h[k] = Hash.new }
                @triggering_dependencies = Hash.new { |h, k| h[k] = ValueSet.new }

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

                tasks.each do |task|
                    initial_information(task)
                    connections = triggering_port_connections(task)
                    triggering_connections[task] = connections
                    triggering_dependencies[task] = connections.map do |port_name, (triggering_ports, _)|
                        triggering_ports.map(&:first)
                    end
                end

                remaining_tasks = tasks.dup
                while !missing_ports.empty?
                    remaining_tasks = remaining_tasks.
                        sort_by { |t| triggering_dependencies[t].size }

                    current_size = @result_size
                    remaining_tasks.delete_if do |task|
                        triggering_connections[task].delete_if do |port_name, (triggers, can_use_any_connection)|
                            if can_use_any_connection && (done_connection = triggers.find { |args| has_final_information_for_port?(*args) })
                                add_port_info(task, port_name, port_info(*done_connection))
                                done_port_info(task, port_name)
                                true
                            elsif !can_use_any_connection && triggers.all? { |args| has_final_information_for_port?(*args) }
                                triggers.each do |info|
                                    add_port_info(task, port_name, port_info(*info))
                                end
                                done_port_info(task, port_name)
                                true
                            else
                                debug do
                                    debug "cannot propagate information to input #{task}.#{port_name}"
                                    debug "  missing info on:"
                                    missing = triggers.find_all { |args| !has_final_information_for_port?(*args) }
                                    missing.each do |missing_task, missing_port|
                                        debug "    #{missing_task}.#{missing_port} (has_info: #{has_information_for_port?(missing_task, missing_port)}, has_final_info: #{has_final_information_for_port?(missing_task, missing_port)}"
                                    end
                                    break
                                end
                                false
                            end
                        end

                        propagate_task(task)
                    end

                    if current_size == @result_size
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
                    debug do
                        debug "done_port_info(#{task}, #{port_name}) called at"
                        @done_at[[task, port_name]].each do |line|
                            debug "  #{line}"
                        end
                        break
                    end
                    raise ArgumentError, "trying to change port information for #{task}.#{port_name} after done_port_info has been called"
                end

                if !has_information_for_port?(task, port_name)
                    @result_size += 1
                    @result[task][port_name] = info
                else
                    @result[task][port_name].merge(info)
                end
            end

            # Deletes all available information about the specified port
            def remove_port_info(task, port_name)
                if !@result.has_key?(task)
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
                debug do
                    debug "done computing information for #{task}.#{port_name}"
                    if has_information_for_port?(task, port_name)
                        debug "  #{port_info(task, port_name)}"
                    else
                        debug "  no stored information"
                    end
                    @done_at ||= Hash.new
                    @done_at[[task, port_name]] = caller
                    break
                end

                if has_information_for_port?(task, port_name)
                    if port_info(task, port_name).empty?
                        remove_port_info(task, port_name)
                    end
                end

                done_ports[task] << port_name
                if missing_ports.has_key?(task)
                    missing_ports[task].delete(port_name)
                    if missing_ports[task].empty?
                        missing_ports.delete(task)
                    end
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
                result = Hash.new
                triggering_inputs(task).each do |port|
                    task.each_concrete_input_connection(port.name) do |from_task, from_port, to_port, _|
                        result[to_port] ||= [Set.new, false]
                        result[to_port].first << [from_task, from_port]
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
        end
    end
end

