# frozen_string_literal: true

module Syskit
    module Models
        # Syskit-side representation of a property
        #
        # Writing on such an object does not write on the task. The write is
        # performed either at configuration time, or when #commit_properties
        # is called
        class Property
            # The task model this property is part of
            #
            # @return [Models::TaskContext]
            attr_reader :task_context

            # This property's name
            #
            # @return [String]
            attr_reader :name

            # This property's type
            #
            # @return [Typelib::Type]
            attr_reader :type

            def initialize(task_context, name, type)
                @task_context = task_context
                @name = name
                @type = type
            end
        end
    end
end
