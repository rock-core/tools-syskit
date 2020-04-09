# frozen_string_literal: true

module Syskit
    module Coordination
        class DataMonitoringErrorMatcher < Roby::Queries::LocalizedErrorMatcher
            # The monitor model that should be matched
            attr_reader :monitor

            def initialize
                super
                with_model(DataMonitoringError)
            end

            def from_monitor(monitor)
                @monitor = monitor
                self
            end

            def ===(exception)
                return false unless super

                exception.monitor.model == monitor
            end
        end
    end
end
