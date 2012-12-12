module Syskit
    # Mixin used to define common methods to enumerate ports on objects that
    # have a model that includes Syskit::Models::PortAccess
    module PortAccess
        # Returns the port object that maps to the given name, or nil if it
        # does not exist.
        def find_port(name)
            name = name.to_str
            find_output_port(name) || find_input_port(name)
        end

        def has_port?(name)
            has_input_port?(name) || has_output_port?(name)
        end

        # Returns the output port with the given name, or nil if it does not
        # exist.
        def find_output_port(name)
            if m = model.find_output_port(name)
                return m.bind(self)
            end
        end

        # Returns the input port with the given name, or nil if it does not
        # exist.
        def find_input_port(name)
            if m = model.find_input_port(name)
                return m.bind(self)
            end
        end

        # Enumerates this component's output ports
        def each_output_port
            model.each_output_port do |p|
                yield(p.bind(self))
            end
        end

        # Enumerates this component's input ports
        def each_input_port
            model.each_input_port do |p|
                yield(p.bind(self))
            end
        end

        # Enumerates all of this component's ports
        def each_port
            return enum_for(:each_port) if !block_given?
            each_output_port { |p| yield(p) }
            each_input_port { |p| yield(p) }
        end

        # Returns true if +name+ is a valid output port name for instances
        # of +self+. If including_dynamic is set to false, only static ports
        # will be considered
        def has_output_port?(name, including_dynamic = true)
            return !!find_output_port(name)
        end

        # Returns true if +name+ is a valid input port name for instances of
        # +self+. If including_dynamic is set to false, only static ports
        # will be considered
        def has_input_port?(name, including_dynamic = true)
            return !!find_input_port(name)
        end

        # Resolves the _port access
        def method_missing(m, *args)
            if args.empty? && !block_given?
                if m.to_s =~ /^(\w+)_port$/
                    port_name = $1
                    if port = self.find_port(port_name)
                        return port
                    else
                        raise NoMethodError, "#{self} has no port called #{port_name}"
                    end
                end
            end
            super
        end

    end
end

