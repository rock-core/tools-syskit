# frozen_string_literal: true

module Syskit
    module Queries
        # Finds {BoundDataService} by type and/or name within the plan
        class DataServiceMatcher < Roby::Queries::MatcherBase
            include AbstractComponentBase

            def initialize(component_matcher)
                super()

                @component_matcher = component_matcher
                @model = [Syskit::DataService]
                @name_filter = Roby::Queries.any
            end

            def data_service_model
                @model.first
            end

            # Filters the matching services by name
            def with_name(name)
                @name_filter = name
                self
            end

            # Filters the services by model
            def with_model(model)
                @model = [model]
                self
            end

            # Make the query return a specific view of the resolved services
            def as(model)
                unless data_service_model.fullfills?(model)
                    raise ArgumentError,
                          "cannot refine match from #{@model.first} to #{model}"
                end

                with_model(model)
            end

            def ===(data_service)
                return unless data_service.kind_of?(BoundDataService)

                (@name_filter === data_service.name) &&
                    (data_service.service_model <= @model.first) &&
                    (@component_matcher === data_service.component)
            end

            def with_exact_name?
                @name_filter.respond_to?(:to_str)
            end

            def with_model_filter?
                @model.first != Syskit::DataService
            end

            def each_in_plan(plan, &block)
                return enum_for(__method__, plan) unless block_given?

                with_exact_name = with_exact_name?
                with_model_filter = with_model_filter?

                if with_exact_name && with_model_filter
                    each_in_plan_by_name_and_model(plan, &block)
                elsif with_exact_name
                    each_in_plan_by_name(plan, &block)
                elsif with_model_filter
                    each_in_plan_by_model(plan, &block)
                else
                    each_in_plan_no_filter(plan, &block)
                end
            end

            def each_in_plan_by_name(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    ds = task.find_data_service(@name_filter)
                    yield(ds) if ds
                end
            end

            def each_in_plan_by_model(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    task.each_data_service do |ds|
                        if ds.service_model.fullfills?(@model.first)
                            yield(ds.as(@model.first))
                        end
                    end
                end
            end

            def each_in_plan_by_name_and_model(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    ds = task.find_data_service(@name_filter)
                    if ds.service_model.fullfills?(@model.first)
                        yield(ds.as(@model.first))
                    end
                end
            end

            def each_in_plan_no_filter(plan)
                @component_matcher.each_in_plan(plan) do |task|
                    task.each_data_service do |_, ds|
                        yield(ds)
                    end
                end
            end

            def respond_to_missing?(name, _)
                if name.to_s.end_with?("_port")
                    super
                else
                    @component_matcher.respond_to?(name)
                end
            end

            def method_missing(name, *args)
                if name.to_s.end_with?("_port")
                    super
                else
                    @component_matcher.send(name, *args)
                    self
                end
            end
        end
    end
end
