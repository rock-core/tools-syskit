# frozen_string_literal: true

module Syskit
    module Queries
        # Specialization of {Roby::Queries::TaskMatcher} which gives access
        # to data services and ports
        class ComponentMatcher < Roby::Queries::TaskMatcher
            include AbstractComponentBase
        end
    end
end
