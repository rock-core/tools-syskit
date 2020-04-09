# frozen_string_literal: true

module Syskit
    module Coordination
        # Exception issued by the data monitors in {DataMonitor#poll} when
        # predicate#finalize returns true
        class DataMonitoringError < Roby::LocalizedError
            attr_reader :monitor
            attr_reader :time
            attr_reader :samples

            def initialize(task, monitor, time, samples)
                super(task)
                @monitor = monitor
                @time = time
                @samples = samples
            end

            def pretty_print(pp)
                pp.text "data monitor #{monitor} triggered at #{time}, with data samples "
                pp.seplist(samples) do |s|
                    s.pretty_print(pp)
                end
                pp.breakable
                super
            end
        end
    end
end
