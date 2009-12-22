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
                end
                model
            end

            def create_orogen_interface
                interface = Roby.app.main_orogen_project.
                    task_context "roby_#{name}".camelcase(true)
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

            def each_port_name_candidate(port_name, main_source = false, source_names = nil)
                if !block_given?
                    return enum_for(:each_port_name_candidate, port_name, main_source, source_names)
                end

                if source_names
                    if main_source
                        yield(port_name)
                    end
                    source_names.each do |source_name|
                        yield("#{source_name}_#{port_name}".camelcase(false))
                        yield("#{port_name}_#{source_name}".camelcase(false))
                    end
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

            # Verifies if +model+ has the outputs required by having +self+ as a
            # data source. +main_source+ says if the match should consider that
            # the new source would be a main source, and +source_name+ is the
            # tentative source name.
            def implemented_by?(model, main_source = false, source_name = nil)
                return true if !orogen_spec

                each_output do |source_port|
                    has_eqv = each_port_name_candidate(source_port.name, main_source, source_name).any? do |port_name|
                        port = model.output_port(port_name)
                        port && port.type_name == source_port.type_name
                    end
                    return false if !has_eqv
                end
                each_input do |source_port|
                    has_eqv = each_port_name_candidate(source_port.name, main_source, source_name).any? do |port_name|
                        port = model.input_port(port_name)
                        port && port.type_name == source_port.type_name
                    end
                    return false if !has_eqv
                end
                true
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
            # data source on the target
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

            # Returns true if +self+ can replace +other_task+ in the plan. The
            # super() call checks graph-declared dependencies (i.e. that all
            # dependencies that +other_task+ meets are also met by +self+.
            #
            # This method checks that +other_task+ and +self+ do not represent
            # two different data sources
            def can_merge?(other_task)
                return false if !super

                each_merged_source(other_task) do |selection, other_name, self_names, source_type|
                    if self_names.empty?
                        return false
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
                    arguments["#{target_name}_name"] = selection

                    # What we also need to do is map port names from the ports
                    # in +merged_task+ into the ports in +self+
                    #
                    # For that, we first build a name mapping and then we apply
                    # it by moving edges from +merged_task+ into +self+.
                    if DataSourceModel.needs_port_mapping?(merged_task.model, other_name, model, target_name)
                        raise NotImplementedError, "mapping data flow ports is not implemented yet"
                    end
                end

                # Copy arguments of +merged_task+ that are not yet assigned in
                # +self+
                merged_task.arguments.each do |key, value|
                    arguments[key] ||= value if !arguments.has_key?(key)
                end

                # Finally, remove +merged_task+ from the data flow graph and use
                # #replace_task to replace it completely
                plan.replace_task(merged_task, self)
                nil
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

            # The output port name for the +bus_name+ device attached on this
            # bus
            def output_name_for(bus_name)
                bus_name
            end

            # The input port name for the +bus_name+ device attached on this bus
            def input_name_for(bus_name)
                "#{bus_name}w"
            end
        end

        class Component::TransactionProxy < Roby::Transactions::Task
            proxy_for Component
            include DataSource
        end
        Flows.apply_on Component::TransactionProxy
    end
end


