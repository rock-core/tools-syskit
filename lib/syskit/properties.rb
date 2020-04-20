# frozen_string_literal: true

module Syskit
    # A hash wrapper that gives access to properties in a more manageable way
    # than using a hash or using {TaskContext#property} and
    # {TaskContext#method_missing}
    #
    # E.g.
    #
    #    task.properties.test = 10
    #    task.properties.test # => 10
    #
    class Properties < BasicObject
        def initialize(task, properties)
            @task = task
            @properties = properties
        end

        # Enumerate the properties
        def each(&block)
            @properties.each_value(&block)
        end

        # Whether there is a property with this name
        def include?(name)
            @properties.key?(name.to_str)
        end

        # Clear all written values
        def clear_values
            @properties.each_value(&:clear_value)
        end

        # Returns a property by name
        #
        # @return [Property,nil]
        def [](name)
            @properties[name.to_str]
        end

        def __resolve_property(name)
            if p = @properties[name.to_str]
                [false, p]
            elsif name.start_with?("raw_")
                non_raw_name = name[4..-1]
                if p = @properties[non_raw_name]
                    [true, p]
                else
                    ::Kernel.raise ::Orocos::NotFound, "neither #{non_raw_name} nor #{name} are a property of #{@task}"
                end
            else
                ::Kernel.raise ::Orocos::NotFound, "#{name} is not a property of #{@task}"
            end
        end

        def method_missing(m, *args)
            if m =~ /=$/
                raw, p = __resolve_property($`.to_s)
                if raw
                    p.raw_write(*args)
                else
                    p.write(*args)
                end
            else
                raw, p = __resolve_property(m.to_s)

                if raw
                    value = p.raw_read(*args)
                    if ::Kernel.block_given?
                        p.raw_write(yield(value))
                    else
                        value
                    end
                else
                    value = p.read(*args)
                    if ::Kernel.block_given?
                        p.write(yield(value))
                    else
                        value
                    end
                end
            end
        end
    end
end
