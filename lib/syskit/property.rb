module Syskit
    # Syskit-side representation of a property
    #
    # Writing on such an object does not write on the task. The write is
    # performed either at configuration time, or when #commit_properties
    # is called
    class Property
        # This property's task context
        #
        # @return [TaskContext]
        attr_reader :task_context

        # This property's name
        # 
        # @return [String]
        attr_reader :name

        # This property's type
        # 
        # @return [String]
        attr_reader :type

        # The value of this property on the component side
        # 
        # @return [Typelib::Type]
        attr_reader :remote_value

        # The value that would be applied on this property next time
        # TaskContext#commit_properties is called
        #
        # @return [Typelib::Type]
        attr_reader :value

        # The metadata for the log stream
        attr_reader :log_metadata

        # The stream on which this property is logged
        # @return [nil,#write]
        attr_accessor :log_stream
        
        # The remote property
        #
        # It is used as a cache mechanism, and should never be used directly.
        # It is initialized and accessed by the API on {TaskContext}
        attr_accessor :remote_property

        # Whether this property is being logged
        def logged?
            !!log_stream
        end

        def initialize(task_context, name, type)
            @task_context = task_context
            @name  = name
            @type  = type
            @remote_value = nil
            @value = nil
            @log_stream = nil
            @log_metadata = Hash.new
            @remote_property = nil
        end

        # Whether a value has been set with {#write}
        def has_value?
            !!@value
        end

        # Add metadata to {#log_metadata}
        def update_log_metadata(metadata)
            log_metadata.merge!(metadata)
        end

        # Update the known value for the property on the node side
        #
        # @param [Object] value a valid value for the property. It will be
        #   converted to the propertie's own type
        def update_remote_value(value)
            @remote_value = Typelib.from_ruby(value, type).dup
        end

        # Whether this property needs to be written on the remote side
        def needs_commit?
            @value && (!@remote_value || (@value != @remote_value))
        end

        # Read the current Syskit-side value of this property
        # 
        # This is not necessarily the value on the component side
        def read
            Typelib.to_ruby(@value)
        end

        # Read the current Syskit-side value of this property as a Typelib
        # object
        # 
        # This is not necessarily the value on the component side
        def raw_read
            @value
        end

        # Request updating this property with the given value
        #
        # The property will be updated only at the task's configuration time, or
        # when TaskContext#commit_properties is called.
        #
        # @param [Typelib::Type,Object] value the property value
        # @param [Time] _timestamp ignored, for compatibility with
        #   {Orocos::Property}
        def write(value, _timestamp = nil)
            if task_context.would_use_property_update?
                raw_write(Typelib.from_ruby(value, type))
            end
        end

        # Update this property with a Typelib object
        #
        # The object's type and value will not be checked
        def raw_write(value, _timestap = nil)
            if value.class != type
                raise ArgumentError, "expected a typelib value of type #{type}, but got #{value.class}"
            end
            @value = value
            task_context.queue_property_update_if_needed
        end

        # Remove the current value
        #
        # This will in effect ensure that the property won't get written
        def clear_value
            @value = nil
        end

        # Update the log stream with the currently none remote value
        def update_log(timestamp = Time.now, value = self.remote_value)
            if logged?
                log_stream.write(timestamp, timestamp, value)
            end
        end
    end
end

