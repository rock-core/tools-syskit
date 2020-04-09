# frozen_string_literal: true

module Syskit
    # Representation of a selection context, as a stack of
    # DependencyInjection objects
    #
    # This represents a prioritized set of selections (as
    # DependencyInjection objects). It is mainly used during instanciation
    # to find _what_ should be instanciated.
    #
    # In the stack, the latest selection added with #push takes priority
    # over everything that has been added before it. During resolution, if
    # nothing is found at a certain level, then the previous levels will be
    # queried.
    #
    # Use #selection_for and #candidates_for to query the selection. Use
    # #save, #restore and #push to manage the stack
    class DependencyInjectionContext
        StackLevel = Struct.new :resolver, :added_info

        # The stack of StackLevel objects added with #push
        attr_reader :stack
        # The resolved selections. When a query is made at a certain level
        # of the stack, it gets resolved into one single explicit selection
        # hash, to optimize repeated queries.
        attr_reader :state
        # The list of savepoints
        #
        # They are stored as sizes of +stack+. I.e. #restore simply resizes
        # +stack+ and +state+ to the size stored in +save.last+
        attr_reader :savepoints

        # Creates a new dependency injection context
        #
        # +base+ is the root selection context (can be nil). It can either
        # be a hash or a DependencyInjection object. In the first case, it
        # is interpreted as a selection hash usable in
        # DependencyInjection#use, and is converted to the corresponding
        # DependencyInjection object this way.
        def initialize(base = nil)
            @stack = []
            @state = []
            @savepoints = []

            # Add a guard on the stack, so that #push does not have to care
            stack << StackLevel.new(DependencyInjection.new, DependencyInjection.new)

            case base
            when Hash
                deps = DependencyInjection.new(base)
                push(deps)
            when DependencyInjection
                push(base)
            when NilClass
                nil
            else
                raise ArgumentError,
                      "expected either a selection hash or a DependencyInjection "\
                      "object as base selection, got #{base}"
            end
        end

        def initialize_copy(obj)
            @stack = obj.stack.dup
            @state = obj.state.dup
            @savepoints = obj.savepoints.dup
        end

        def pretty_print(pp)
            current_state.pretty_print(pp)
        end

        # Push all DI information in the given context at the top of the
        # stack of this context
        def concat(context)
            context.stack.each do |di|
                push(di.added_info.dup)
            end
        end

        # Pushes the current state of the context on the save stack.
        # #restore will go back to this exact state, regardless of the
        # number of {push} calls, and {pop} will stop at the last savepoint
        #
        # The save/restore mechanism is stack-based, so when doing
        #
        #   save
        #   save
        #   restore
        #   restore
        #
        # The first restore returns to the state in the second save and the
        # second restore returns to the state in thef first save.
        #
        # @overload save()
        #   adds a savepoint that is going to be restored by the matching
        #   {#restore} call
        # @overload save() { }
        #   saves the current state, executes the block and calls {#restore}
        #   when the execution quits the block
        # @return [void]
        def save
            if !block_given?
                @savepoints << stack.size
            else
                save
                begin
                    yield
                ensure
                    restore
                end
            end
        end

        # Returns the resolved state of the selection stack, as a
        # DependencyInjection object.
        #
        # Calling #candidates_for and #selection_for on the resolved object
        # is equivalent to resolving the complete stack
        def current_state
            stack.last.resolver
        end

        # The opposite of {#save}
        #
        # Save and restore calls are paired. See #save for more information.
        def restore
            expected_size = @savepoints.pop
            unless expected_size
                raise ArgumentError, "save/restore stack is empty"
            end

            @stack = stack[0, expected_size]
            if state.size > expected_size
                @state = state[0, expected_size]
            end
        end

        # Returns all the candidates that match +criteria+ in the current
        # state of this context
        #
        # (see DependencyInjection#selection_for)
        def selection_for(name, requirements)
            current_state.selection_for(name, requirements)
        end

        # (see DependencyInjection#has_selection_for?)
        def has_selection_for?(name)
            current_state.has_selection_for?(name)
        end

        # Returns a non-ambiguous selection for the given criteria
        #
        # Returns nil if no selection is defined, or if there is an
        # ambiguity (i.e. multiple candidates exist)
        #
        # See DependencyInjection#candidates_for for the format of
        # +criteria+
        #
        # See also #candidates_for
        def instance_selection_for(name, requirements)
            current_state.instance_selection_for(name, requirements)
        end

        def push_mask(mask)
            if mask.empty?
                stack << StackLevel.new(stack.last.resolver, DependencyInjection.new)
                return
            end
            spec = DependencyInjection.new
            spec.add_mask(mask)
            new_state = stack.last.resolver.dup
            new_state.add_mask(mask)
            stack << StackLevel.new(new_state, spec)
        end

        def empty?
            stack.size == 1
        end

        # Adds a new dependency injection context on the stack
        def push(spec)
            if spec.empty?
                stack << StackLevel.new(stack.last.resolver, DependencyInjection.new)
                return
            end

            spec = DependencyInjection.new(spec)

            new_state = stack.last.resolver.dup
            # Resolve all names
            unresolved = spec.resolve_names(new_state.explicit)
            unless unresolved.empty?
                raise NameResolutionError.new(unresolved), "could not resolve names while pushing #{spec} on #{self}"
            end

            # Resolve recursive selection, and default selections
            spec.resolve_default_selections
            # Finally, add it to the new state
            new_state.add(spec)
            new_state.resolve!
            # ... and to the stack
            stack << StackLevel.new(new_state, spec)
        end

        # Returns the StackLevel object representing the last added level on
        # the stack
        #
        # @return [StackLevel]
        def top
            stack.last
        end

        # Removes the last dependency injection context stored on the stack,
        # and returns it.
        #
        # Will stop at the last saved context (saved with #save). Returns
        # nil in this case
        #
        # @return [StackLevel,nil]
        def pop
            if stack.size == 1
                return StackLevel.new(DependencyInjection.new, DependencyInjection.new)
            end

            expected_size = @savepoints.last
            if expected_size && expected_size == stack.size
                return
            end

            result = stack.pop
            if state.size > stack.size
                @state = state[0, stack.size]
            end
            result
        end
    end
end
