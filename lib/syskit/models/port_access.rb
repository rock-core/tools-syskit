# frozen_string_literal: true

module Syskit
    module Models
        # Mixin used to define common methods to enumerate ports on objects that
        # have an attribute #orogen_model of type Orocos::Spec::TaskContext
        module PortAccess
            # [Hash{String => Syskit::Models::Port}] a mapping from a port name
            # to the corresponding Models::Port instance
            attribute(:ports) { {} }

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m, "_port" => :has_port?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args, "_port" => :find_port
                ) || super
            end

            # Returns the port object that maps to the given name, or nil if it
            # does not exist.
            def find_port(name)
                name = name.to_str
                find_output_port(name) || find_input_port(name)
            end

            def port_by_name(name)
                if p = find_port(name)
                    p
                else raise ArgumentError, "#{self} has no port called #{name}, known ports are: #{each_port.map(&:name).sort.join(', ')}"
                end
            end

            # Returns the output port with the given name, or nil if it does not
            # exist.
            def find_output_port(name)
                name = name.to_str
                if port_model = orogen_model.find_output_port(name)
                    ports[name] ||= OutputPort.new(self, port_model)
                end
            end

            # Returns the input port with the given name, or nil if it does not
            # exist.
            def find_input_port(name)
                name = name.to_str
                if port_model = orogen_model.find_input_port(name)
                    ports[name] ||= InputPort.new(self, port_model)
                end
            end

            # Enumerates all of this component's ports
            def each_port(&block)
                return enum_for(:each_port) unless block_given?

                each_output_port(&block)
                each_input_port(&block)
            end

            # Enumerates this component's output ports
            def each_output_port
                return enum_for(:each_output_port) unless block_given?

                orogen_model.each_output_port do |p|
                    yield(ports[p.name] ||= OutputPort.new(self, p))
                end
            end

            # Enumerates this component's input ports
            def each_input_port
                return enum_for(:each_input_port) unless block_given?

                orogen_model.each_input_port do |p|
                    yield(ports[p.name] ||= InputPort.new(self, p))
                end
            end

            def has_port?(name)
                name = name.to_str
                has_input_port?(name) || has_output_port?(name)
            end

            # Returns true if +name+ is a valid output port name for instances
            # of +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_output_port?(name, including_dynamic = true)
                return true if find_output_port(name)

                if including_dynamic
                    has_dynamic_output_port?(name)
                end
            end

            # Returns true if +name+ is a valid input port name for instances of
            # +self+. If including_dynamic is set to false, only static ports
            # will be considered
            def has_input_port?(name, including_dynamic = true)
                return true if find_input_port(name)

                if including_dynamic
                    has_dynamic_input_port?(name)
                end
            end

            # True if +name+ could be a dynamic output port name.
            #
            # Dynamic output ports are declared on the task models using the
            # #dynamic_output_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_output_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic output port declarations using this predicate.
            def has_dynamic_output_port?(name, type = nil)
                if type
                    type = Roby.app.default_loader.opaque_type_for(type)
                end
                orogen_model.has_dynamic_output_port?(name, type)
            end

            # True if +name+ could be a dynamic input port name.
            #
            # Dynamic input ports are declared on the task models using the
            # #dynamic_input_port statement, e.g.:
            #
            #   data_service do
            #       dynamic_input_port /name_pattern\w+/, "/std/string"
            #   end
            #
            # One can then match if a given string (+name+) matches one of the
            # dynamic input port declarations using this predicate.
            def has_dynamic_input_port?(name, type = nil)
                if type
                    type = Roby.app.default_loader.opaque_type_for(type)
                end
                orogen_model.has_dynamic_input_port?(name, type)
            end
        end
    end
end
