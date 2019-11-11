module Syskit
    # Syskit-side representation of the property of an actual live task
    class LiveProperty < Property
        # The underlying task context
        attr_reader :task_context

        # The remote property
        #
        # It is used as a cache mechanism, and should never be used directly.
        # It is initialized and accessed by the API on {TaskContext}
        attr_accessor :remote_property

        # Whether this property is being logged
        def logged?
            log_stream
        end

        def initialize(task_context, name, type)
            super(name, type)
            @task_context = task_context
            @remote_property = nil
        end

        # Whether this property needs to be written on the remote side
        def needs_commit?
            @value && (!@remote_value || (@value != @remote_value))
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
                super
            end
        end

        # Update this property with a Typelib object
        #
        # The object's type and value will not be checked
        def raw_write(value, _timestap = nil)
            super
            task_context.queue_property_update_if_needed
        end
    end
end

