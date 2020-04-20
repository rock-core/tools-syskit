# frozen_string_literal: true

module Syskit
    module NetworkGeneration
        class << self
            # Margin that should be added to the computed buffer sizes. It is a
            # ratio of the optimal buffer size
            #
            # I.e. if a connection requires 5 buffers and that value is 0.1,
            # then the actual buffer size will be 6 (it is rounded upwards).
            #
            # If the buffer size is 400, then 440 will be used in the end
            #
            # The default is 0.1 (10%)
            attr_reader :buffer_size_margin

            # Sets the margin that should be added to the computed buffer sizes
            #
            # See #buffer_size_margin for more explanations
            def buffer_size_margin=(value)
                value = Float(value)
                if value < 0
                    raise ArgumentError, "only positive values can be used as "\
                                         "buffer_size_margin, got #{value}"
                end
                @buffer_size_margin = Float(value)
            end
        end
        self.buffer_size_margin = 0.1

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

                attr_reader :hash

                def initialize(name, period, sample_count)
                    @name = name.to_str
                    @period = period
                    @sample_count = sample_count
                    @hash = [@name, @period, @sample_count].hash
                    freeze
                end

                def eql?(other)
                    @period == other.period &&
                        @name == other.name &&
                        @sample_count == other.sample_count
                end

                def ==(other)
                    eql?(other)
                end
            end

            def initialize(name, sample_size = 1)
                @name = name
                @sample_size = sample_size.to_int
                @triggers = Set.new
            end

            def empty?
                triggers.empty?
            end

            def add_trigger(name, period, sample_count)
                return if sample_count == 0

                DataFlowDynamics.debug do
                    "  [#{self.name}]: adding trigger from #{name} -"\
                    " #{period} #{sample_count}"
                end
                triggers << Trigger.new(name, period, sample_count)
            end

            def merge(other_dynamics)
                return if other_dynamics.equal?(self)

                DataFlowDynamics.debug do
                    DataFlowDynamics.debug "adding triggers from #{other_dynamics.name} to #{name}"
                    DataFlowDynamics.log_nest(4) do
                        DataFlowDynamics.log_pp(:debug, other_dynamics)
                    end
                    break
                end
                triggers.merge(other_dynamics.triggers)
                true
            end

            def minimal_period
                triggers.map(&:period).min
            end

            def sampled_at(duration)
                result = PortDynamics.new(name, sample_size)
                names = triggers.map(&:name)
                result.add_trigger("#{name}.resample(#{names.join(',')},#{duration})", duration, queue_size(duration))
                result
            end

            def sample_count(duration)
                triggers.map do |trigger|
                    if trigger.period == 0
                        trigger.sample_count
                    else
                        (duration / trigger.period).floor * trigger.sample_count
                    end
                end.inject(&:+)
            end

            def queue_size(duration)
                (1 + sample_count(duration)) * sample_size
            end

            def pretty_print(pp)
                pp.seplist(triggers) do |tr|
                    pp.text "(#{tr.name}): #{tr.period} #{tr.sample_count}"
                end
            end
        end

        # Algorithms that make use of the dataflow modelling
        #
        # The main task of this class is to compute the update rates and the
        # default policies for each of the existing connections in +plan+. The
        # resulting information is stored in #dynamics
        class DataFlowDynamics < DataFlowComputation
            attr_reader :plan

            attr_reader :triggers

            # Mapping from a deployed task name to the corresponding Roby task object
            #
            # This is necessary to speedup lookup in some places of the algorithm
            attr_reader :task_from_name

            def initialize(plan)
                @plan = plan
                super()
            end

            def self.compute_connection_policies(plan)
                engine = DataFlowDynamics.new(plan)
                engine.compute_connection_policies
                engine.result
            end

            def reset(tasks = [])
                super
                @triggers = Hash.new { |h, k| h[k] = Set.new }
                @task_from_name = {}
                tasks.each do |t|
                    task_from_name[t.orocos_name] = t
                end
            end

            def has_information_for_task?(task)
                has_information_for_port?(task, nil)
            end

            def has_final_information_for_task?(task)
                has_final_information_for_port?(task, nil)
            end

            def add_task_trigger(task, name, period, burst)
                add_port_trigger(task, nil, name, period, burst)
            end

            def add_task_info(task, info)
                add_port_info(task, nil, info)
            end

            def task_info(task)
                port_info(task, nil)
            end

            def done_task_info(task)
                task.orogen_model.slaves.each do |slave_task|
                    if slave_task = task_from_name[slave_task.name]
                        add_task_info(slave_task, task_info(task))
                        done_task_info(slave_task)
                    end
                end
                done_port_info(task, nil)
            end

            def create_port_info(task, port_name)
                port_model = task.model.find_port(port_name)
                dynamics = PortDynamics.new("#{task.orocos_name}.#{port_model.name}",
                                            port_model.sample_size)
                dynamics.add_trigger("burst", port_model.burst_period, port_model.burst_size)
                set_port_info(task, port_name, dynamics)
                dynamics
            end

            def add_port_trigger(task, port_name, name, period, burst)
                if has_information_for_port?(task, port_name)
                    @result[task][port_name].add_trigger(name, period, burst)
                else
                    info = create_port_info(task, port_name)
                    info.add_trigger(name, period, burst)
                    info
                end
            end

            # Adds triggering information from the attached devices to +task+'s ports
            def initial_device_information(task)
                triggering_devices = task.model.each_master_driver_service.map do |srv|
                    [srv, task.find_device_attached_to(srv)]
                end
                DataFlowDynamics.debug do
                    DataFlowDynamics.debug "initial port dynamics on #{task} (device)"
                    DataFlowDynamics.debug "  attached devices: #{triggering_devices.map { |srv, dev| "#{dev.name} on #{srv.name}" }.join(', ')}"
                    break
                end

                activity_type = task.orogen_model.activity_type.name
                case activity_type
                when "Periodic"
                    initial_device_information_periodic_triggering(
                        task, triggering_devices.to_a, task.orogen_model.period
                    )
                else
                    initial_device_information_internal_triggering(
                        task, triggering_devices.to_a
                    )
                end
            end

            # Common external loop for adding initial device information in
            # #initial_device_information. It is used by
            # initial_device_information_periodic_triggering and
            # initial_device_information_internal_triggering
            def initial_device_information_common(task, triggering_devices)
                triggering_devices.each do |service, device|
                    DataFlowDynamics.debug do
                        "  #{device.name}: #{device.period} #{device.burst}"
                    end
                    device_dynamics = PortDynamics.new(device.name, 1)
                    if device.period
                        device_dynamics.add_trigger(device.name, device.period, 1)
                    end
                    device_dynamics.add_trigger(device.name + "-burst", 0, device.burst)

                    yield(service, device, device_dynamics) unless device_dynamics.empty?
                end
            end

            # Computes the initial port dynamics due to devices when the task
            # gets triggered by the devices it is attached to
            def initial_device_information_internal_triggering(task, triggering_devices)
                DataFlowDynamics.debug "  is triggered internally"

                initial_device_information_common(task, triggering_devices) do |service, device, device_dynamics|
                    add_task_info(task, device_dynamics)
                    service.each_output_port do |out_port|
                        out_port = out_port.to_component_port
                        out_port.orogen_model.triggered_on_update = false
                        add_port_info(task, out_port.name, device_dynamics)
                        done_port_info(task, out_port.name)
                    end
                end
            end

            # Computes the initial port dynamics due to devices when the task is
            # triggered periodically
            def initial_device_information_periodic_triggering(task, triggering_devices, period)
                DataFlowDynamics.debug do
                    "  is triggered with a period of #{period} seconds"
                end

                initial_device_information_common(task, triggering_devices) do |service, device, device_dynamics|
                    service.each_output_port do |out_port|
                        out_port = out_port.to_component_port
                        out_port.orogen_model.triggered_on_update = false
                        add_port_trigger(
                            task, out_port.name, device.name, period,
                            device_dynamics.queue_size(period)
                        )
                        done_port_info(task, out_port.name)
                    end
                end
            end

            # Computes the initial port dynamics due to the devices that go
            # through a communication bus.
            def initial_combus_information(task)
                handled_ports = Set.new
                DataFlowDynamics.debug do
                    "adding information from attached combus devices"
                end

                task.each_attached_device do |dev|
                    srv = task.find_data_service(dev.name)
                    DataFlowDynamics.debug do
                        "  #{dev.name}, period: #{dev.period} burst: #{dev.burst}"
                    end
                    srv.each_output_port do |port|
                        port = port.to_component_port
                        handled_ports << port.name
                        dynamics = PortDynamics.new(
                            "#{task.orocos_name}.#{port.name}", dev.sample_size
                        )
                        if dev.period
                            dynamics.add_trigger(dev.name, dev.period, dev.sample_size)
                        end
                        if dev.burst != 0
                            dynamics.add_trigger("#{dev.name}-burst", 0,
                                                 dev.burst * dev.sample_size)
                        end
                        add_port_info(task, port.name, dynamics)
                        DataFlowDynamics.debug do
                            DataFlowDynamics.debug "  #{port.name}:"
                            DataFlowDynamics.log_nest(4) do
                                DataFlowDynamics.log_pp(:debug, dynamics)
                            end
                            break
                        end
                    end
                end
                handled_ports.each do |port_name|
                    done_port_info(task, port_name)
                end
            end

            # Computes the initial port dynamics, i.e. the dynamics that can be
            # computed without knowing anything about the dataflow
            def initial_information(task)
                return if task.orogen_model.master

                initial_task_information(task)
            end

            # @api private
            #
            # Computes a task's slaves initial information
            def initial_slaves_information(task)
                task.orogen_model.slaves.each do |orogen_slave_task|
                    if slave_task = task_from_name[orogen_slave_task.name]
                        unless has_information_for_task?(slave_task)
                            initial_task_information(slave_task)
                        end
                    end
                end
            end

            # @api private
            #
            # Computes a task's initial information
            def initial_task_information(task)
                initial_slaves_information(task)

                set_port_info(task, nil, PortDynamics.new("#{task.orocos_name}.main"))
                task.model.each_output_port do |port|
                    create_port_info(task, port.name)
                end

                add_task_info(task, task.requirements.dynamics.task)
                task.requirements.dynamics.ports.each do |port_name, dynamics|
                    add_port_info(task, port_name, dynamics)
                    done_port_info(task, port_name)
                end

                initial_device_information(task) if task.kind_of?(Device)
                initial_combus_information(task) if task.kind_of?(ComBus)

                activity_type = task.orogen_model.activity_type.name
                if activity_type == "Periodic"
                    DataFlowDynamics.debug { "  adding periodic trigger #{task.orogen_model.period} 1" }
                    add_task_trigger(task, "#{task.orocos_name}.main-period", task.orogen_model.period, 1)
                    done_task_info(task)

                elsif activity_type == "SlaveActivity"
                    # The master's main trigger is propagated in #done_task_info

                elsif !task.model.each_event_port.find { true }
                    done_task_info(task)
                end
            end

            # Computes the set of input ports in +task+ that are used during the
            # information propagation
            def triggering_inputs(task)
                all_triggers = Set.new
                @triggers[[task, nil]] = Set.new
                task.model.each_event_port do |port|
                    if task.has_concrete_input_connection?(port.name)
                        all_triggers << port
                        @triggers[[task, nil]] << [task, port.name]
                    end
                end
                task.model.each_output_port do |port|
                    if port.triggered_on_update?
                        @triggers[[task, port.name]] << [task, nil]
                    end
                    port.port_triggers.each do |trigger_port|
                        if task.has_concrete_input_connection?(trigger_port.name)
                            @triggers[[task, port.name]] << [task, trigger_port.name]
                            all_triggers << trigger_port
                        end
                    end
                end
                task.model.each_output_port do |port|
                    unless @triggers.key?([task, port.name])
                        done_port_info(task, port.name)
                    end
                end

                all_triggers
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
                result = {}
                tasks.each do |t|
                    ports = t.model.each_output_port.to_a
                    unless ports.empty?
                        result[t] = ports.map(&:name).to_set
                        result[t] << nil
                    end
                end
                result
            end

            def find_period_of(task)
                orogen_model = task.orogen_model
                while (master = orogen_model.master)
                    orogen_model = master
                end
                if orogen_model.activity_type.name == "Periodic"
                    orogen_model.period
                end
            end

            # Try to compute the information for the given task and port (or, if
            # port_name is nil, for the task). Returns true if the required
            # information could be computed as requested, and false otherwise.
            def compute_info_for(task, port_name)
                triggers = @triggers[[task, port_name]].map do |trigger_task, trigger_port|
                    if has_final_information_for_port?(trigger_task, trigger_port)
                        port_info(trigger_task, trigger_port)
                    else
                        DataFlowDynamics.debug do
                            DataFlowDynamics.debug "  missing info on "\
                                "#{trigger_task}.#{trigger_port} to compute "\
                                "#{task}.#{port_name}"
                            break
                        end
                        return false
                    end
                end

                if (period = find_period_of(task))
                    triggers = triggers.map do |trigger_info|
                        trigger_info.sampled_at(period)
                    end
                end

                triggers.each do |trigger_info|
                    add_port_info(task, port_name, trigger_info)
                end
                done_port_info(task, port_name)
                true
            end

            def propagate_task(task)
                unless missing_ports.key?(task)
                    return true
                end

                done = true
                required = missing_ports[task].dup
                DataFlowDynamics.debug do
                    DataFlowDynamics.debug "trying to compute dataflow dynamics for #{task}"
                    DataFlowDynamics.debug "  requires information on: #{required.map(&:to_s).join(', ')}"
                    break
                end

                required.each do |missing|
                    unless compute_info_for(task, missing)
                        DataFlowDynamics.debug do
                            DataFlowDynamics.debug "  cannot compute information on #{missing}"
                            break
                        end
                        done = false
                    end
                end
                done
            end

            # Computes desired connection policies, based on the port dynamics
            # and the oroGen's input port specifications. See the user's guide
            # for more details
            #
            # It updates {DataFlow#policy_graph}
            def compute_connection_policies
                # We only act on deployed tasks, as we need to know how the
                # tasks are triggered (what activity / priority / ...)
                deployed_tasks = plan.find_local_tasks(TaskContext)
                                     .find_all(&:execution_agent)

                propagate(deployed_tasks)

                DataFlowDynamics.debug do
                    DataFlowDynamics.debug "computing connections"
                    deployed_tasks.each do |t|
                        DataFlowDynamics.debug "  #{t}"
                    end

                    DataFlowDynamics.debug "available information for"
                    result.each do |task, ports|
                        DataFlowDynamics.debug "  #{task}: #{ports.keys.join(', ')}"
                    end
                    break
                end

                dataflow_graph = plan.task_relation_graph_for(Flows::DataFlow)
                connection_graph = dataflow_graph.compute_concrete_connection_graph
                policy_graph = {}
                deployed_tasks.each do |source_task|
                    compute_policies_from(connection_graph, source_task, policy_graph)
                end
                dataflow_graph.policy_graph = policy_graph
                policy_graph
            end

            # @api private
            #
            # Compute the policies for all connections starting from a given task
            def compute_policies_from(connection_graph, source_task, policy_graph = {})
                connection_graph.each_out_neighbour(source_task) do |sink_task|
                    mappings = connection_graph.edge_info(source_task, sink_task)
                    computed_policies =
                        mappings.each_with_object({}) do |(port_pair, policy), h|
                            policy = policy.dup
                            fallback_policy = policy.delete(:fallback_policy)
                            if policy.empty?
                                h[port_pair] =
                                    policy_for(source_task, *port_pair, sink_task,
                                               fallback_policy)
                            else
                                h[port_pair] = policy
                            end
                        end
                    policy_graph[[source_task, sink_task]] = computed_policies
                end
                policy_graph
            end

            # Given the current knowledge about the port dynamics, returns the
            # policy for the provided connection
            def policy_for(
                source_task, source_port_name, sink_port_name, sink_task, fallback_policy
            )
                source_port = source_task.find_output_port(source_port_name)
                sink_port   = sink_task.find_input_port(sink_port_name)

                unless source_port
                    raise InternalError,
                          "#{source_port_name} is not an output port "\
                          "of #{source_task}"
                end

                unless sink_port
                    raise InternalError,
                          "#{sink_port_name} is not an input port "\
                          "of #{sink_task}"
                end

                DataFlowDynamics.debug do
                    "   #{source_task}:#{source_port.name} => "\
                    "#{sink_task}:#{sink_port.name}"
                end

                sink_port_m = sink_port.model
                if sink_port_m.needs_reliable_connection?
                    compute_reliable_connection_policy(
                        source_port, sink_port, fallback_policy
                    )
                elsif sink_port_m.required_connection_type == :data
                    policy = Orocos::Port.prepare_policy(type: :data)
                    DataFlowDynamics.debug { "     result: #{policy}" }
                    policy
                elsif sink_port_m.required_connection_type == :buffer
                    policy = Orocos::Port.prepare_policy(type: :buffer, size: 1)
                    DataFlowDynamics.debug { "     result: #{policy}" }
                    policy
                else
                    raise UnsupportedConnectionType,
                          "unknown required connection type "\
                          "#{sink_port_m.required_connection_type} "\
                          "on #{sink_port}"
                end
            end

            def compute_reliable_connection_policy(
                source_port, sink_port, fallback_policy
            )
                source_task = source_port.component
                sink_task = sink_port.component

                if has_final_information_for_port?(source_task, source_port.name)
                    source_dynamics = port_info(source_task, source_port.name)
                end

                reading_latency = compute_reading_latency(sink_task, sink_port)

                if source_dynamics && reading_latency
                    compute_buffer_policy(source_dynamics, reading_latency)
                else
                    handle_missing_connection_policy_input(
                        source_task, source_port, sink_port, sink_task,
                        fallback_policy, source_dynamics
                    )
                end
            end

            def handle_missing_connection_policy_input(
                source_task, source_port, sink_port, sink_task,
                fallback_policy, has_source_dynamics
            )
                if fallback_policy
                    warn do
                        if has_source_dynamics
                            warn "#{sink_task} has no minimal period"
                            warn "This is needed to compute the reading latency on "\
                                    "#{sink_port.name}"
                            warn "Specified fallback policy #{fallback_policy} will be used"
                        else
                            warn "Cannot compute the period information for output port"
                            warn "   #{source_task}:#{source_port.name}"
                            warn "   This is needed to compute the policy to connect to"
                            warn "   #{sink_task}:#{sink_port.name}"
                            warn "   The fallback policy #{fallback_policy} will be used"
                        end
                        break
                    end

                    fallback_policy.dup
                elsif !has_source_dynamics
                    raise SpecError,
                          "period information for output port #{source_task}:"\
                          "#{source_port.name} cannot be computed. This is needed "\
                          "to compute the policy to connect to "\
                          "#{sink_task}:#{sink_port.name}"
                else
                    raise SpecError,
                          "#{sink_task} has no minimal period, needed to compute "\
                          "reading latency on #{sink_port.name}"
                end
            end

            def compute_reading_latency(sink_task, sink_port)
                # THere's no nice triggering API on Syskit, and I don't think there
                # should be. Punch through the abstraction layers for the time being
                if sink_task.model.orogen_model.find_port(sink_port.name).trigger_port?
                    sink_task.trigger_latency
                elsif has_final_information_for_task?(sink_task)
                    dynamics = task_info(sink_task)
                    if dynamics.minimal_period
                        dynamics.minimal_period + sink_task.trigger_latency
                    end
                end
            end

            def compute_buffer_policy(source_dynamics, reading_latency)
                size = (1.0 + Syskit.conf.buffer_size_margin) *
                       source_dynamics.queue_size(reading_latency)

                debug do
                    debug "     input_period:#{source_dynamics.minimal_period} => "\
                            "reading_latency:#{reading_latency}"
                    debug "     sample_size:#{source_dynamics.sample_size}"
                    source_dynamics.triggers.each do |tr|
                        debug "     trigger(#{tr.name}): period=#{tr.period} "\
                                "count=#{tr.sample_count}"
                    end
                    break
                end

                policy = { type: :buffer, size: size.ceil }
                debug { "     result: #{policy}" }
                policy
            end
        end
    end
end
