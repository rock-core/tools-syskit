# frozen_string_literal: true

module Syskit
    module Test
        # Test executor for classes that use concurrent-ruby
        #
        # This is meant for testing and debugging. Each call to process_one will
        # process a single queued task in the current thread
        class PollingExecutor < Concurrent::ImmediateExecutor
            def initialize
                super

                @task_queue = Queue.new
            end

            def post(*args, &task)
                @task_queue << [args, task]
            end

            def take_one_task
                @task_queue.pop(true)
            rescue ThreadError
                # queue full
            end

            def execute_one
                args, task = take_one_task
                task&.call(*args)
                task
            end

            def execute_all
                while execute_one
                end
            end
        end
    end
end
