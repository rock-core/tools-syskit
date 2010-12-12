module Orocos
    module RobyPlugin
        # A representation of the actual dynamics of a port
        #
        # At the last stages, the Engine object will try to create and update
        # PortDynamics for each known ports.
        #
        # The PortDynamics objects maintain a list of so-called 'triggers'. One
        # trigger represents a single periodic event on a port (i.e. reception
        # on an input port and emission on an output port). It states that the
        # port will receive/send Trigger#sample_count samples at a period of
        # Trigger#period. If period is zero, it means that it will happend
        # "every once in a while".
        #
        # A sample is virtual: it is not an actual data sample on the
        # connection. The translation between both is given by
        # PortDynamics#sample_size.
        #
        # To update and propagate these port dynamics along the data flow, the
        # Engine uses the TaskContext#initial_ports_dynamics,
        # TaskContext#propagate_ports_dynamics and
        # TaskContext#propagate_ports_dynamics methods implemented by the tasks
        # and data sources
        #
        class PortDynamics
            # The name of the port we are computing dynamics for. This is used
            # for debugging purposes only
            attr_reader :name
            # The number of data samples per trigger, if the port's model value
            # needs to be overriden
            attr_reader :sample_size
            # The set of registered triggers for this port, as a list of
            # Trigger objects, where +period+ is in seconds and
            # sample_count is the count of samples sent at +period+ intervals
            attr_reader :triggers

            class Trigger
                attr_reader :name
                attr_reader :period
                attr_reader :sample_count

                def initialize(name, period, sample_count)
                    @name, @period, @sample_count =
                        name, period, sample_count
                end
            end

            def initialize(name, sample_size = 1)
                @name = name
                @sample_size = sample_size.to_int
                @triggers = Array.new
            end

            def empty?; triggers.empty? end

            def add_trigger(name, period, sample_count)
                if sample_count != 0
                    Engine.debug { "  [#{self.name}]: adding trigger from #{name} - #{period} #{sample_count}" }
                    triggers << Trigger.new(name, period, sample_count).freeze
                end
            end

            def merge(other_dynamics)
                Engine.debug do
                    Engine.debug "  adding triggers from #{other_dynamics.name} to #{name}"
                    other_dynamics.triggers.each do |tr|
                        Engine.debug "    (#{tr.name}): #{tr.period} #{tr.sample_count}"
                    end
                    break
                end
                triggers.concat(other_dynamics.triggers)
            end

            def minimal_period
                triggers.map(&:period).min
            end

            def sample_count(duration)
                triggers.map do |trigger|
                    if trigger.period == 0
                        trigger.sample_count
                    else
                        (duration/trigger.period).floor * trigger.sample_count
                    end
                end.inject(&:+)
            end

            def queue_size(duration)
                (1 + sample_count(duration)) * sample_size
            end
        end

        # Algorithms that make use of the dataflow modelling
        #
        # The main task of this class is to compute the update rates and the
        # default policies for each of the existing connections in +plan+. The
        # resulting information is stored in #dynamics
        class DataFlowDynamics
            attr_reader :plan

            # The result of #propagate is stored in this attribute
            attr_reader :port_dynamics

            def initialize(plan)
                @plan = plan
            end

            def self.compute_connection_policies(plan)
                engine = DataFlowDynamics.new(plan)
                engine.compute_connection_policies
            end

            # Compute the dataflow information along the connections that exist
            # in the plan
            def propagate(deployed_tasks)
                # Get the periods from the activities themselves directly (i.e.
                # not taking into account the port-driven behaviour)
                #
                # We also precompute relevant connections, as they won't change
                # during the computation
                result = Hash.new
                triggering_connections  = Hash.new { |h, k| h[k] = Array.new }
                triggering_dependencies = Hash.new { |h, k| h[k] = ValueSet.new }
                deployed_tasks.each do |task|
                    result[task] = task.initial_ports_dynamics

                    # First, add all connections that will trigger the target
                    # task
                    task.orogen_spec.task_model.each_event_port do |port|
                        task.each_concrete_input_connection(port.name) do |from_task, from_port, to_port, _|
                            triggering_connections[task] << [from_task, from_port, to_port]
                            triggering_dependencies[task] << from_task
                        end
                    end
                    
                    # Then register the connections that will make one port be
                    # updated
                    task.orogen_spec.task_model.each_output_port do |port|
                        port.port_triggers.each do |port_trigger_name|
                            # No need to re-register if it already triggering
                            # the task
                            next if task.model.triggered_by?(port_trigger_name)

                            task.each_concrete_input_connection(port_trigger_name) do |from_task, from_port, to_port, _|
                                triggering_connections[task] << [from_task, from_port, to_port]
                                triggering_dependencies[task] << from_task
                            end
                       end
                    end
                end

                remaining = deployed_tasks.dup
                propagated_port_to_port = Hash.new { |h, k| h[k] = Set.new }
                while !remaining.empty?
                    remaining = remaining.
                        sort_by { |t| triggering_dependencies[t].size }

                    did_something = false
                    remaining.delete_if do |task|
                        old_size = result[task].size
                        finished = task.
                            propagate_ports_dynamics(triggering_connections[task], result)
                        if finished
                            did_something = true
                            task.propagate_ports_dynamics_on_outputs(result[task], propagated_port_to_port[task], true)
                            triggering_dependencies.delete(task)
                        elsif result[task].size != old_size
                            did_something = true
                        end
                        finished
                    end

                    if !did_something
                        # If we are blocked unfinished, try to propagate some
                        # port-to-port information to see if it unblocks the
                        # thing.
                        remaining.each do |task|
                            did_something ||= task.
                                propagate_ports_dynamics_on_outputs(result[task], propagated_port_to_port[task], false)
                        end
                    end

                    if !did_something
                        Engine.info do
                            Engine.info "cannot compute port periods for:"
                            remaining.each do |task|
                                port_names = task.model.each_input_port.map(&:name) + task.model.each_output_port.map(&:name)
                                port_names.delete_if { |port_name| result[task].has_key?(port_name) }

                                Engine.info "    #{task}: #{port_names.join(", ")}"
                            end
                            break
                        end
                        break
                    end
                end

                Engine.debug do
                    result.each do |task, ports|
                        Engine.debug "#{task.name}:"
                        if dyn = task.task_dynamics
                            Engine.debug "  period=#{dyn.minimal_period}"
                            dyn.triggers.each do |tr|
                                Engine.debug "  trigger(#{tr.name}): period=#{tr.period} count=#{tr.sample_count}"
                            end
                        end
                        ports.each do |port_name, dyn|
                            port_model = task.model.find_port(port_name)
                            next if !port_model.kind_of?(Orocos::Generation::OutputPort)

                            Engine.debug "  #{port_name}"
                            Engine.debug "    period=#{dyn.minimal_period} sample_size=#{dyn.sample_size}"
                            dyn.triggers.each do |tr|
                                Engine.debug "    trigger(#{tr.name}): period=#{tr.period} count=#{tr.sample_count}"
                            end
                        end
                    end
                    break
                end

                result
            end

            # Computes desired connection policies, based on the port dynamics
            # (computed by #port_dynamics) and the oroGen's input port
            # specifications. See the user's guide for more details
            #
            # It directly modifies the policies in the data flow graph
            def compute_connection_policies
                # We only act on deployed tasks, as we need to know how the
                # tasks are triggered (what activity / priority / ...)
                deployed_tasks = plan.find_local_tasks(TaskContext).
                    find_all(&:execution_agent)
                
                port_dynamics = propagate(deployed_tasks)
                @port_dynamics = port_dynamics

                Engine.debug "computing connections"

                deployed_tasks.each do |source_task|
                    source_task.each_concrete_output_connection do |source_port_name, sink_port_name, sink_task, policy|
                        # Don't do anything if the policy has already been set
                        if !policy.empty?
                            Engine.debug " #{source_task}:#{source_port_name} => #{sink_task}:#{sink_port_name} already connected with #{policy}"
                            next
                        end

                        source_port = source_task.find_output_port_model(source_port_name)
                        sink_port   = sink_task.find_input_port_model(sink_port_name)
                        if !source_port
                            raise InternalError, "#{source_port_name} is not a port of #{source_task.model}"
                        elsif !sink_port
                            raise InternalError, "#{sink_port_name} is not a port of #{sink_task.model}"
                        end
                        Engine.debug { "   #{source_task}:#{source_port.name} => #{sink_task}:#{sink_port.name}" }

                        if !sink_port.needs_reliable_connection?
                            if sink_port.required_connection_type == :data
                                policy.merge! Port.validate_policy(:type => :data)
                                Engine.debug { "     result: #{policy}" }
                                next
                            elsif sink_port.required_connection_type == :buffer
                                policy.merge! Port.validate_policy(:type => :buffer, :size => 1)
                                Engine.debug { "     result: #{policy}" }
                                next
                            end
                        end

                        # Compute the buffer size
                        input_dynamics = port_dynamics[source_task][source_port.name]
                        if !input_dynamics || input_dynamics.empty?
                            raise SpecError, "period information for output port #{source_task}:#{source_port.name} cannot be computed. This is needed to compute the policy to connect to #{sink_task}:#{sink_port_name}"
                        end

                        reading_latency =
                            if sink_task.model.triggered_by?(sink_port)
                                sink_task.trigger_latency
                            elsif !sink_task.minimal_period
                                raise SpecError, "#{sink_task} has no minimal period, needed to compute reading latency on #{sink_port.name}"
                            else
                                sink_task.minimal_period + sink_task.trigger_latency
                            end

                        policy[:type] = :buffer
                        policy[:size] = input_dynamics.queue_size(reading_latency)
                        Engine.debug do
                            Engine.debug "     input_period:#{input_dynamics.minimal_period} => reading_latency:#{reading_latency}"
                            Engine.debug "     sample_size:#{input_dynamics.sample_size}"
                            input_dynamics.triggers.each do |tr|
                                Engine.debug "     trigger(#{tr.name}): period=#{tr.period} count=#{tr.sample_count}"
                            end
                            break
                        end
                        policy.merge! Port.validate_policy(policy)
                        Engine.debug { "     result: #{policy}" }
                    end
                end
            end
        end
    end
end

