# frozen_string_literal: true

module Syskit
    # Mixin used to define common methods to enumerate ports on objects that
    # have a model that includes Syskit::Models::PortAccess
    module PortAccess
        # Returns the port object that maps to the given name, or nil if it
        # does not exist.
        #
        # @parma [String] name
        # @return [Syskit::Port,nil]
        def find_port(name)
            name = name.to_str
            find_output_port(name) || find_input_port(name)
        end

        def has_port?(name)
            name = name.to_str
            has_input_port?(name) || has_output_port?(name)
        end

        # Finds the port that has the given name
        #
        # @param [String] name the name of the port
        # @return [Syskit::Port] the port
        # @raises [ArgumentError] if the port does not exist
        def port_by_name(name)
            p = find_port(name)
            return p if p

            known_ports = each_port.map(&:name).sort.join(", ")
            raise ArgumentError,
                  "'#{name}' is not a port of #{self}. Known ports are: #{known_ports}"
        end

        # Returns the output port with the given name, or nil if it does not
        # exist.
        def find_output_port(name)
            if m = model.find_output_port(name)
                m.bind(self)
            end
        end

        # Returns the input port with the given name, or nil if it does not
        # exist.
        def find_input_port(name)
            if m = model.find_input_port(name)
                m.bind(self)
            end
        end

        # Enumerates this component's output ports
        def each_output_port
            return enum_for(:each_output_port) unless block_given?

            model.each_output_port do |p|
                yield(p.bind(self))
            end
        end

        # Enumerates this component's input ports
        def each_input_port
            return enum_for(:each_input_port) unless block_given?

            model.each_input_port do |p|
                yield(p.bind(self))
            end
        end

        # Enumerates all of this component's ports
        def each_port
            return enum_for(:each_port) unless block_given?

            each_output_port { |p| yield(p) }
            each_input_port { |p| yield(p) }
        end

        # Returns true if +name+ is a valid output port name for instances
        # of +self+. If including_dynamic is set to false, only static ports
        # will be considered
        def has_output_port?(name, including_dynamic = true)
            !!find_output_port(name)
        end

        # Returns true if +name+ is a valid input port name for instances of
        # +self+. If including_dynamic is set to false, only static ports
        # will be considered
        def has_input_port?(name, including_dynamic = true)
            !!find_input_port(name)
        end

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
    end
end
