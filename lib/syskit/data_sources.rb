module Orocos
    module RobyPlugin
        module Interfaces
            def self.each
                constants.each do |name|
                    yield(const_get(name))
                end
            end
        end
        module DeviceDrivers
            def self.each
                constants.each do |name|
                    yield(const_get(name))
                end
            end
        end

        IF = Interfaces
        DD = DeviceDrivers

        # Base type for data source models (DataSource, DeviceDriver,
        # ComBusDriver). Methods defined in this class are available on said
        # models (for instance DeviceDriver.new_submodel)
        class DataSourceModel < Roby::TaskModelTag
            # The name of the model
            attr_accessor :name
            # The parent model, if any
            attr_reader :parent_model

            # Creates a new DataSourceModel that is a submodel of +self+
            def new_submodel(name, options = Hash.new)
                options = Kernel.validate_options options,
                    :type => self.class, :interface => nil

                model = options[:type].new
                model.include self
                model.instance_variable_set(:@parent_model, self)
                model.name = name.to_str

                if options[:interface] != false
                    if options[:interface]
                        iface_spec = Roby.app.get_orocos_task_model(options[:interface]).orogen_spec

                        # If we also have an interface, verify that the two
                        # interfaces are compatible
                        if interface 
                            if !iface_spec.implements?(interface.name)
                                raise SpecError, "data source #{name}'s interface, #{options[:interface].name} is not a specialization of #{self.name}'s interface #{self.interface.name}"
                            end
                        end
                        model.instance_variable_set(:@orogen_spec, iface_spec)
                    elsif interface
                        child_spec = model.create_orogen_interface
                        child_spec.subclasses interface.name
                        model.instance_variable_set :@orogen_spec, child_spec
                    else
                        model.instance_variable_set :@orogen_spec, model.create_orogen_interface
                    end
                end
                model
            end

            def create_orogen_interface
                basename = "roby_#{name}".camelcase(true)
                if Roby.app.main_orogen_project.find_task_context(basename)
                    basename << "_DD"
                end

                interface = Roby.app.main_orogen_project.
                    external_task_context(basename)
                interface.abstract
                interface
            end

            attr_reader :orogen_spec

            def interface(&block)
                if block_given?
                    @orogen_spec ||= create_orogen_interface
                    orogen_spec.instance_eval(&block)
                end
                orogen_spec
            end

            def each_port_name_candidate(port_name, main_source = false, source_name = nil)
                if !block_given?
                    return enum_for(:each_port_name_candidate, port_name, main_source, source_name)
                end

                if source_name
                    if main_source
                        yield(port_name)
                    end
                    yield("#{source_name}_#{port_name}".camelcase(false))
                    yield("#{port_name}_#{source_name}".camelcase(false))
                else
                    yield(port_name)
                end
                self
            end

            # Try to guess the name under which a data source whose model is
            # +self+ could be declared on +model+, by following port name rules.
            #
            # Returns nil if no match has been found
            def guess_source_name(model)
                port_list = lambda do |m|
                    result = Hash.new { |h, k| h[k] = Array.new }
                    m.each_output do |source_port|
                        result[ [true, source_port.type_name] ] << source_port.name
                    end
                    m.each_input do |source_port|
                        result[ [false, source_port.type_name] ] << source_port.name
                    end
                    result
                end

                required_ports  = port_list[self]
                available_ports = port_list[model]

                candidates = nil
                required_ports.each do |spec, names|
                    return if !available_ports.has_key?(spec)

                    available_names = available_ports[spec]
                    names.each do |required_name|
                        matches = available_names.map do |n|
                            if n == required_name then ''
                            elsif n =~ /^(.+)#{Regexp.quote(required_name).capitalize}$/
                                $1
                            elsif n =~ /^#{Regexp.quote(required_name)}(.+)$/
                                name = $1
                                name[0, 1] = name[0, 1].downcase
                                name
                            end
                        end.compact

                        if !candidates
                            candidates = matches
                        else
                            candidates.delete_if { |candidate_name| !matches.include?(candidate_name) }
                        end
                        return if candidates.empty?
                    end
                end

                candidates
            end

            # Verifies if +model+ has the ports required by having +self+ as a
            # data source. +main_source+ says if the match should consider that
            # the new source would be a main source, and +source_name+ is the
            # tentative source name.
            #
            # Raises SpecError if it does not match
            def verify_implemented_by(model, main_source = false, source_name = nil)
                # If this data source defines no interface, return right away
                return if !orogen_spec

                each_output do |source_port|
                    has_eqv = each_port_name_candidate(source_port.name, main_source, source_name).any? do |port_name|
                        port = model.output_port(port_name)
                        port && port.type_name == source_port.type_name
                    end
                    if !has_eqv
                        raise SpecError, "#{model} does not implement #{self}: the #{source_port.name}[#{source_port.type.name}] output port has no equivalent"
                    end
                end
                each_input do |source_port|
                    has_eqv = each_port_name_candidate(source_port.name, main_source, source_name).any? do |port_name|
                        port = model.input_port(port_name)
                        port && port.type_name == source_port.type_name
                    end
                    if !has_eqv
                        raise SpecError, "#{model} does not implement #{self}: the #{source_port.name}[#{source_port.type.name}] output port has no equivalent"
                    end
                end
                nil
            end

            # Like #verify_implemented_by, but returns true if it matches and
            # false otherwise
            def implemented_by?(model, main_source = false, source_name = nil)
                verify_implemented_by(model, main_source, source_name)
                true
            rescue SpecError
                false
            end

            # Returns true if a port mapping is needed between the two given
            # data sources. Note that this relation is symmetric.
            #
            # It is assumed that the name0 source in model0 and the name1 source
            # in model1 are of compatible types (same types or derived types)
            def self.needs_port_mapping?(model0, name0, model1, name1)
                name0 != name1 && !(model0.main_data_source?(name0) && model1.main_data_source?(name1))
            end

            # Computes the port mapping from a plain data source to the given
            # data source on the target. +source+ is the interface model and
            # +target+ the task model we want to select a source on.
            #
            # The returned hash is of the form
            #
            #   source_port_name => target_port_name
            #
            # where +source_port_name+ is the data source port and
            # +target_port_name+ is the actual port on +target+
            def self.compute_port_mappings(source, target, target_name)
                if source < Roby::Task
                    raise InternalError, "#{source} should have been a plain data source, but it is a task model"
                end

                result = Hash.new
                source.each_port do |source_port|
                    result[source_port.name] = target.source_port(source, target_name, source_port.name)
                end
                result
            end

            # Returns the most generic task model that implements +self+. If
            # more than one task model is found, raises Ambiguous
            def task_model
                if @task_model
                    return @task_model
                end

                @task_model = Class.new(TaskContext) do
                    class << self
                        attr_accessor :name
                    end
                end
                @task_model.instance_variable_set(:@orogen_spec, orogen_spec)
                @task_model.abstract
                @task_model.name = "#{name}DataSourceTask"
                @task_model.extend Model
                @task_model.data_source self
                @task_model
            end

            include ComponentModel

            def instanciate(*args, &block)
                task_model.instanciate(*args, &block)
            end

            def to_s # :nodoc:
                "#<DataSource: #{name}>"
            end
        end

        DataSource   = DataSourceModel.new
        DeviceDriver = DataSourceModel.new
        ComBusDriver = DataSourceModel.new

        module DataSource
            module ClassExtension
                def each_child_data_source(parent_name, &block)
                    each_data_source(nil).
                        find_all { |name, model| name =~ /^#{parent_name}\./ }.
                        map { |name, model| [name.gsub(/^#{parent_name}\./, ''), model] }.
                        each(&block)
                end

                # Returns the parent_name, child_name pair for the given source
                # name. child_name is empty if the source is a root source.
                def break_data_source_name(name)
                    name.split '.'
                end

                # Returns true if +name+ is a root data source in this component
                def root_data_source?(name)
                    name = name.to_str
                    if !has_data_source?(name)
                        raise ArgumentError, "there is no source named #{name} in #{self}"
                    end
                    name !~ /\./
                end

                # Returns true if +name+ is a main data source on this component
                def main_data_source?(name)
                    name = name.to_str
                    if !has_data_source?(name)
                        raise ArgumentError, "there is no source named #{name} in #{self}"
                    end
                    each_main_data_source.any? { |source_name| source_name == name }
                end

                def find_data_sources(&block)
                    each_data_source.find_all(&block)
                end

                # Generic data source selection method, based on a source type
                # and an optional source name. It implements the following
                # algorithm:
                #  
                #  * only sources that match +target_model+ are considered
                #  * if there is only one source of that type and no pattern is
                #    given, that source is returned
                #  * if there is a pattern given, it must be either the source
                #    full name or its subname (for slaves)
                #  * if an ambiguity is found between root and slave data
                #    sources, and there is only one root data source matching,
                #    that data source is returned.
                def find_matching_source(target_model, pattern = nil)
                    # Find sources in +child_model+ that match the type
                    # specification
                    matching_sources = self.
                        find_data_sources { |_, source_type| source_type <= target_model }.
                        map { |source_name, _| source_name }

                    if pattern # explicit selection
                        # Find the selected source. There can be shortcuts, so
                        # for instance bla.left would be able to select both the
                        # 'left' main source or the 'bla.blo.left' slave source.
                        rx = /(^|\.)#{pattern}$/
                        matching_sources.delete_if { |name| name !~ rx }
                        if matching_sources.empty?
                            raise SpecError, "no source of type #{target_model.name} with the name #{pattern} exists in #{name}"
                        end
                    else
                        if matching_sources.empty?
                            raise InternalError, "no data source of type #{target_model} found in #{self}"
                        end
                    end

                    selected_name = nil
                    if matching_sources.size > 1
                        main_matching_sources = matching_sources.find_all { |source_name| root_data_source?(source_name) }
                        if main_matching_sources.size != 1
                            raise Ambiguous, "there is more than one source of type #{target_model.name} in #{self.name}: #{matching_sources.map { |n, _| n }.join(", ")}); you must select one explicitely with a 'use' statement"
                        end
                        selected_name = main_matching_sources.first
                    else
                        selected_name = matching_sources.first
                    end

                    selected_name
                end
                    

                def data_source_name(matching_type)
                    candidates = each_data_source.find_all do |name, type|
                        type == matching_type
                    end
                    if candidates.empty?
                        raise ArgumentError, "no source of type '#{type_name}' declared on #{self}"
                    elsif candidates.size > 1
                        raise ArgumentError, "multiple sources of type #{type_name} are declared on #{self}"
                    end
                    candidates.first.first
                end

                # Returns the type of the given data source, or raises
                # ArgumentError if no such source is declared on this model
                def data_source_type(name)
                    each_data_source(name) do |type|
                        return type
                    end
                    raise ArgumentError, "no source #{name} is declared on #{self}"
                end

                # call-seq:
                #   TaskModel.each_root_data_source do |name, source_model|
                #   end
                #
                # Enumerates all sources that are root (i.e. not slave of other
                # sources)
                def each_root_data_source(&block)
                    each_data_source(nil).
                        find_all { |name, _| root_data_source?(name) }.
                        each(&block)
                end
            end

            # Returns true if +self+ can replace +target_task+ in the plan. The
            # super() call checks graph-declared dependencies (i.e. that all
            # dependencies that +target_task+ meets are also met by +self+.
            #
            # This method checks that +target_task+ and +self+ do not represent
            # two different data sources
            def can_merge?(target_task)
                return false if !super
                return if !target_task.kind_of?(DataSource)

                # Check that for each data source in +target_task+, we can
                # allocate a corresponding source in +self+
                each_merged_source(target_task) do |selection, other_name, self_names, source_type|
                    if self_names.empty?
                        return false
                    end

                    # Note: implementing port mapping will require to apply the
                    # port mappings to the test below as well (i.e. which tests
                    # that inputs are free/compatible)
                    if DataSourceModel.needs_port_mapping?(target_task.model, other_name, model, self_names.first)
                        raise NotImplementedError, "mapping data flow ports is not implemented yet"
                    end
                end

                true
            end

            # Replace +merged_task+ by +self+, possibly modifying +self+ so that
            # it is possible.
            def merge(merged_task)
                # First thing to do is reassign data sources from the merged
                # task into ourselves. Note that we do that only for sources
                # that are actually in use.
                each_merged_source(merged_task) do |selection, other_name, self_names, source_type|
                    if self_names.empty?
                        raise SpecError, "trying to merge #{merged_task} into #{self}, but that seems to not be possible"
                    elsif self_names.size > 1
                        raise Ambiguous, "merging #{self} and #{merged_task} is ambiguous: the #{self_names.join(", ")} data sources could be used"
                    end

                    # "select" one source to use to handle other_name
                    target_name = self_names.pop
                    # set the argument
                    if arguments["#{target_name}_name"] != selection
                        arguments["#{target_name}_name"] = selection
                    end

                    # What we also need to do is map port names from the ports
                    # in +merged_task+ into the ports in +self+
                    #
                    # For that, we first build a name mapping and then we apply
                    # it by moving edges from +merged_task+ into +self+.
                    if DataSourceModel.needs_port_mapping?(merged_task.model, other_name, model, target_name)
                        raise NotImplementedError, "mapping data flow ports is not implemented yet"
                    end
                end

                super
            end

            # Returns true if at least one port of the given source (designated
            # by its name) is connected to something.
            def using_data_source?(source_name)
                source_type = model.data_source_type(source_name)
                inputs  = source_type.each_input.
                    map { |p| model.source_port(source_type, source_name, p.name) }
                outputs = source_type.each_output.
                    map { |p| model.source_port(source_type, source_name, p.name) }

                each_source do |output|
                    description = output[self, Flows::DataFlow]
                    if description.any? { |(_, to), _| inputs.include?(to) }
                        return true
                    end
                end
                each_sink do |input, description|
                    if description.any? { |(from, _), _| outputs.include?(from) }
                        return true
                    end
                end
                false
            end

            # Finds the sources of +other_task+ that are in use, and yields
            # merge candidates in +self+
            def each_merged_source(other_task) # :nodoc:
                other_task.model.each_root_data_source do |other_name, other_type|
                    other_selection = other_task.selected_data_source(other_name)
                    next if !other_selection

                    self_selection = nil
                    available_sources = model.each_data_source.find_all do |self_name, self_type|
                        self_selection = selected_data_source(self_name)

                        self_type == other_type &&
                            (!self_selection || self_selection == other_selection)
                    end

                    if self_selection != other_selection
                        yield(other_selection, other_name, available_sources.map(&:first), other_type)
                    end
                end
            end

            extend ClassExtension
        end

        # Module that represents the device drivers in the task models. It
        # defines the methods that are available on task instances. For
        # methods that are available at the task model level, see
        # DeviceDriver::ClassExtension
        module DeviceDriver
            argument "com_bus"

            module ClassExtension
                def each_device(&block)
                    each_root_data_source.
                        find_all { |_, model| model < DeviceDriver }.
                        each(&block)
                end
            end

            def robot_device(subname = nil)
                devices = model.each_device.to_a
                if !subname
                    if devices.empty?
                        raise ArgumentError, "#{self} does not handle any device"
                    elsif devices.size > 1
                        raise ArgumentError, "#{self} handles more than one device, you must specify one explicitely"
                    end
                else
                    devices = devices.find_all { |name, _| name == subname }
                    if devices.empty?
                        raise ArgumentError, "there is no device called #{subname} on #{self}"
                    end
                end
                interface_name, device_model = *devices.first

                device_name = arguments["#{interface_name}_name"]
                return if !device_name

                description = robot.devices[device_name]
                if !description
                    raise ArgumentError, "there is no device called #{device_name} (selected for #{interface_name} on #{self})"
                end
                description
            end

            def bus_name
                if arguments[:bus_name]
                    arguments[:bus_name]
                else
                    roots = model.each_root_data_source.to_a
                    if roots.size == 1
                        roots.first.first
                    end
                end
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result.merge(super)
                end

                triggering_devices = model.each_root_data_source.
                    find_all { |_, model| model < DeviceDriver }.
                    map do |source_name, _|
                        device = robot.devices[arguments["#{source_name}_name"]]
                        if !device
                            RobyPlugin::Engine.warn "no device associated with #{source_name} (#{arguments["#{source_name}_name"]})"
                        end
                        device
                    end.compact

                if orogen_spec.activity_type != 'FileDescriptorActivity'
                    triggering_devices.delete_if { |m| !m.com_bus }
                end

                triggering_devices.each do |device_instance|
                    period = device_instance.period
                    next if !period

                    update_minimal_period(period)

                    source_model, source_name = device_instance.device_model,
                        device_instance.task_source_name

                    source_model.each_output do |port|
                        port_name = model.source_port(source_model, source_name, port.name)
                        port = model.port(port_name)
                        result[port_name] ||= PortDynamics.new(nil, 1)
                        result[port_name].period = [result[port_name].period, period * port.period].compact.min
                    end
                end

                result
            end

            include DataSource

            @name = "DeviceDriver"
            module ModuleExtension
                def to_s # :nodoc:
                    "#<DeviceDriver: #{name}>"
                end

                def task_model
                    model = super
                    model.name = "#{name}DeviceDriverTask"
                    model
                end
            end
            extend ModuleExtension
        end

        # Module that represents the communication busses in the task models. It
        # defines the methods that are available on task instances. For methods
        # that are added to the task models, see ComBus::ClassExtension
        module ComBusDriver
            # Communication busses are also device drivers
            include DeviceDriver

            def self.to_s # :nodoc:
                "#<ComBusDriver: #{name}>"
            end

            def self.new_submodel(model, options = Hash.new)
                bus_options, options = Kernel.filter_options options,
                    :message_type => nil

                model = super(model, options)
                model.class_eval <<-EOD
                module ModuleExtension
                    def message_type
                        \"#{bus_options[:message_type]}\" || (super if defined? super)
                    end
                end
                extend ModuleExtension
                EOD
                model
            end

            def each_connected_device(&block)
                if !block_given?
                    return enum_for(:each_connected_device)
                end

                each_concrete_output_connection do |source_port, sink_port, sink_task|
                    devices = sink_task.model.each_root_data_source.
                        find_all { |_, model| model < DeviceDriver }.
                        map { |source_name, _| robot.devices[sink_task.arguments["#{source_name}_name"]] }.
                        compact.find_all { |device| device.com_bus }

                    yield(source_port, devices)
                end
            end

            def initial_ports_dynamics
                result = Hash.new
                if defined? super
                    result = super
                end

                each_connected_device do |port, devices|
                    result[port] = PortDynamics.new(devices.map(&:period).compact.min,
                                                    devices.map(&:sample_size).compact.inject(&:+))
                end

                result
            end

            # The output port name for the +bus_name+ device attached on this
            # bus
            def output_name_for(bus_name)
                bus_name
            end

            # The input port name for the +bus_name+ device attached on this bus
            def input_name_for(bus_name)
                "w#{bus_name}"
            end
        end
    end
end


