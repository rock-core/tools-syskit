# frozen_string_literal: true

module Syskit
    module Queries
        # Finds a set of ports within the plan
        class PortMatcher < Roby::Queries::MatcherBase
            def initialize(component_matcher)
                @component_matcher = component_matcher.match
                @name_filter = Roby::Queries.any
                @type_filter = nil
            end

            # Resolves the port direction if possible
            #
            # @return [nil,:input,:output]
            def try_resolve_direction
                return unless @name_filter.respond_to?(:to_str)

                begin
                    port = @component_matcher.find_port_by_name(@name_filter)
                    return unless port
                rescue Ambiguous
                    return
                end

                port.output? ? :output : :input
            end

            # Resolves the port type if possible
            #
            # @return [nil,Class<Typelib::Type>]
            def try_resolve_type
                return @type_filter if @type_filter
                return unless @name_filter.respond_to?(:to_str)

                begin
                    @component_matcher.find_port_by_name(@name_filter)
                                      &.type
                rescue Ambiguous # rubocop:disable Lint/SuppressedException
                end
            end

            # Filters the ports by name
            def with_name(name)
                @name_filter = name
                self
            end

            # Filters the ports by type
            def with_type(type)
                @type_filter = type
                self
            end

            def ===(port)
                return unless port.kind_of?(Port)

                (@name_filter === object.name) &&
                    (!@type_filter || @type_filter == object.type) &&
                    (@component_matcher === object.component)
            end

            def each_in_plan(plan, &block)
                return enum_for(__method__, plan) unless block_given?

                if @name_filter.respond_to?(:to_str)
                    each_in_plan_by_name(plan, &block)
                else
                    each_in_plan_generic(plan, &block)
                end
            end

            def each_in_plan_by_name(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    if (port = task.find_port(@name_filter))
                        yield(port) if !@type_filter || @type_filter == port.type
                    end
                end
            end

            def each_in_plan_generic(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    task.each_port do |p|
                        if @name_filter === p.name &&
                           (!@type_filter || @type_filter == p.type)
                            yield(p)
                        end
                    end
                end
            end
        end
    end
end
